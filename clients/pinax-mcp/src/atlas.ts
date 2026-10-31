// Atlas — a queryable index over ANY Pinax `agent.json`. Pure (no MCP, no I/O beyond the initial
// load), so it is usable as a plain library: `loadAtlas(path).search("...")`. The MCP server in
// server.ts is just one frontend over this.
//
// Every unit (part, page, section, and every node in one: prose, figure, table, code, check, raw) is
// addressable by its id — Pinax ids are globally unique within a document (they key the comment
// store), so a single id -> unit map is the index.
import { existsSync, readFileSync, realpathSync } from "node:fs";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { AgentDocZ, type AgentDoc, type Check, type ContentRef, type Page } from "./schema.js";

export type UnitKind =
  | "part"
  | "page"
  | "section"
  | "text"
  | "figure"
  | "table"
  | "code"
  | "raw"
  | "check";

export interface Unit {
  kind: UnitKind;
  id: string;
  /** A human label: the title for a part/page/section, the caption for a figure. */
  label: string;
  /** The containing unit's id (a page's part, a section's page, a figure's section or page). */
  parent?: string;
  /** The raw agent.json node, returned verbatim by `get_unit` / resource reads. */
  node: any;
}

export interface SearchHit {
  id: string;
  kind: UnitKind;
  label: string;
  field: string;
  snippet: string;
}

/** A path an agent.json names, as written and as resolved inside its directory. */
export interface Located {
  rel: string;
  abs: string;
}

// whether `path` is `dir` or lies under it (both absolute, symlinks already resolved or both not)
function within(dir: string, path: string): boolean {
  const r = relative(dir, path);
  return r !== ".." && !r.startsWith(`..${sep}`) && !isAbsolute(r);
}

const firstLine = (s: string): string => s.split("\n")[0];

// The leaf nodes a page or section holds, in index order: the array each lives in, its kind, and the
// label a reader would recognise it by.
const LEAVES: { key: string; kind: UnitKind; label: (n: any) => string }[] = [
  { key: "texts", kind: "text", label: (t) => firstLine(t.text) }, // a prose block: its first line
  { key: "figures", kind: "figure", label: (f) => f.caption },
  { key: "tables", kind: "table", label: (t) => t.caption || t.id },
  { key: "codes", kind: "code", label: (b) => b.caption || firstLine(b.source) }, // else its first line
  { key: "checks", kind: "check", label: (c) => c.label },
  { key: "raws", kind: "raw", label: (r) => firstLine(r.html) }, // a @raw block: its first line of HTML
];

// ---- search: the text fields each kind of unit is searched in, beyond its label ----

type Field = [field: string, text: string | null | undefined];

const commentFields = (n: any): Field[] =>
  (n.comments ?? []).map((c: any): Field => ["comment", `${c.author}: ${c.text}`]);
// a cell's text: avoid [object Object] / nested-array join
const cellText = (c: unknown): string => (c == null ? "" : String(c));
const cellsText = (rows: unknown[][] = []): string => rows.map((r) => r.map(cellText).join(" ")).join(" | ");
const paramsFields = (params: unknown): Field[] => (typeof params === "string" ? [["params", params]] : []);
// a part, section or check: its desc and its comments; a page adds its summary
const containerFields = (n: any): Field[] => [["desc", n.desc], ...commentFields(n)];

const SEARCHED: Record<UnitKind, (n: any) => Field[]> = {
  figure: (n) => [["code", n.code], ...paramsFields(n.params), ...commentFields(n)],
  code: (n) => [["code", n.source]],
  text: (n) => [["text", n.text]],
  raw: (n) => [["html", n.html]],
  table: (n) => [["cells", cellsText(n.rows)], ...commentFields(n)],
  page: (n) => [["desc", n.desc], ["summary", n.summary], ...commentFields(n)],
  part: containerFields,
  section: containerFields,
  check: containerFields,
};

const SNIPPET_CONTEXT = 30;

// The text around a match at `i` of length `len`, whitespace folded, with "…" where text was cut.
function snippet(text: string, i: number, len: number): string {
  const start = Math.max(0, i - SNIPPET_CONTEXT);
  const end = i + len + SNIPPET_CONTEXT;
  const slice = text.slice(start, end).replace(/\s+/g, " ").trim();
  return (start > 0 ? "…" : "") + slice + (end < text.length ? "…" : "");
}

// A hit when the lower-cased query `q` occurs in `text`, else none.
function hitIn(u: Unit, [field, text]: Field, q: string): SearchHit[] {
  const i = text ? text.toLowerCase().indexOf(q) : -1;
  if (i < 0) return [];
  return [{ id: u.id, kind: u.kind, label: u.label, field, snippet: snippet(text!, i, q.length) }];
}

// ---- outline helpers ----

// A check's result as the outline states it (the schema fills an older check's outcome from `pass`).
const checkResult = (n: Check): string => n.outcome.toUpperCase();

// a container's verdict over its subtree ("" when it holds no checks — never a vacuous PASS)
const verdictOf = (node: any): string =>
  node.verdict ? `  [${node.verdict.verdict} ${node.verdict.passed}/${node.verdict.total}]` : "";

function pageHeading(page: Page): string {
  const summary = page.summary ? ` — ${page.summary}` : "";
  const status = page.status && page.status !== "final" ? ` [status: ${page.status}]` : "";
  return `\n### [page ${page.id}] ${page.title}${status}${summary}${verdictOf(page)}`;
}

// with no content at all (an older agent.json), a container lists its figures, then its tables
const fallbackLines = (node: any): string[] => [
  ...(node.figures ?? []).map((f: any) => `- [figure ${f.id}] ${f.caption}`),
  ...(node.tables ?? []).map((t: any) => `- [table ${t.id}] ${t.caption || t.id}`),
];

// what the build and the render recorded (a node a face left out, a failed figure), so a reader
// sees the gaps rather than inferring them
const diagnosticLines = (doc: AgentDoc): string[] => {
  const diags = doc.diagnostics ?? [];
  if (!diags.length) return [];
  return ["\n## Diagnostics", ...diags.map((d) => `- [${d.severity}] ${d.item}: ${d.message}`)];
};

export class Atlas {
  readonly doc: AgentDoc;
  /** Directory of the agent.json, used to resolve the relative asset paths it references. */
  readonly baseDir: string;
  private units = new Map<string, Unit>();
  private order: string[] = [];

  constructor(doc: AgentDoc, baseDir: string) {
    this.doc = doc;
    this.baseDir = resolve(baseDir);
    this.build();
  }

  private add(u: Unit): void {
    // ids are globally unique within a Pinax document; on the rare hand-built clash, first wins.
    if (this.units.has(u.id)) return;
    this.units.set(u.id, u);
    this.order.push(u.id);
  }

  private build(): void {
    for (const part of this.doc.parts) {
      this.add({ kind: "part", id: part.id, label: part.title, node: part });
    }
    for (const page of this.doc.pages) {
      this.add({
        kind: "page",
        id: page.id,
        label: page.title,
        parent: page.part ?? undefined,
        node: page,
      });
      this.addLeaves(page, page.id);
      for (const sec of page.sections) this.addSection(sec, page.id);
    }
  }

  // A container's prose, figures, tables, code blocks, checks and @raw blocks, each under its id.
  private addLeaves(node: any, parent: string): void {
    for (const { key, kind, label } of LEAVES) {
      for (const n of node[key] ?? []) this.add({ kind, id: n.id, label: label(n), parent, node: n });
    }
  }

  // Sections nest to any depth; each child is indexed under its parent section.
  private addSection(sec: any, parent: string): void {
    this.add({ kind: "section", id: sec.id, label: sec.title, parent, node: sec });
    this.addLeaves(sec, sec.id);
    for (const child of sec.sections ?? []) this.addSection(child, sec.id);
  }

  unit(id: string): Unit | undefined {
    return this.units.get(id);
  }

  all(kind?: UnitKind): Unit[] {
    const us = this.order.map((id) => this.units.get(id)!);
    return kind ? us.filter((u) => u.kind === kind) : us;
  }

  /** A token-lean text outline of the whole document: every node, in reading order, with its id. */
  outline(): string {
    const out: string[] = [`# ${this.doc.title}`];
    this.outlinePages(out);
    out.push(...diagnosticLines(this.doc));
    return out.join("\n");
  }

  // each page under a heading, and a part's heading before the first page of each run in that part
  private outlinePages(out: string[]): void {
    const partTitle = new Map(this.doc.parts.map((p) => [p.id, p.title]));
    let lastPart: string | null = null;
    for (const page of this.doc.pages) {
      const pid = page.part ?? null;
      if (pid !== lastPart && pid) out.push(`\n## [part ${pid}] ${partTitle.get(pid) ?? pid}`);
      lastPart = pid;
      out.push(pageHeading(page));
      this.outlineContent(out, page, 4);
    }
  }

  // a section's heading one level deeper per depth (a top-level section is ####), then its content
  private outlineSection(out: string[], sec: any, level: number): void {
    out.push(`${"#".repeat(level)} [section ${sec.id}] ${sec.title}${verdictOf(sec)}`);
    this.outlineContent(out, sec, level + 1);
  }

  // walk a page/section's `content` in declaration order, a nested section where it stands; a
  // section the content does not list follows (an older agent.json); with no content at all, fall
  // back to figures-then-tables.
  private outlineContent(out: string[], node: any, level: number): void {
    const content: ContentRef[] = node.content ?? [];
    const sections: any[] = node.sections ?? [];
    if (content.length) for (const ref of content) this.outlineRef(out, ref, sections, level);
    else out.push(...fallbackLines(node));
    const listed = new Set(content.filter((r) => r.kind === "section").map((r) => r.id));
    for (const sec of sections) if (!listed.has(sec.id)) this.outlineSection(out, sec, level);
  }

  private outlineRef(out: string[], { kind, id }: ContentRef, sections: any[], level: number): void {
    const sec = kind === "section" ? sections.find((s) => s.id === id) : undefined;
    if (sec) return this.outlineSection(out, sec, level);
    // emit even an unresolvable id (stale agent.json) so it is visible, not silently dropped
    out.push(`- [${kind} ${id}] ${this.refLabel(id)}`);
  }

  // a check leads with its result, so a reader sees PASS/FAIL/ERROR before the expression
  private refLabel(id: string): string {
    const u = this.unit(id);
    if (!u) return "(missing)";
    return u.kind === "check" ? `${checkResult(u.node)} ${u.label}` : u.label;
  }

  /** Case-insensitive substring search over labels, descriptions, summaries, code, and comments. */
  search(query: string): SearchHit[] {
    const q = query.toLowerCase();
    if (q.length === 0) return [];
    return this.all().flatMap((u) =>
      [["label", u.label] as Field, ...SEARCHED[u.kind](u.node)].flatMap((f) => hitIn(u, f, q)),
    );
  }

  /** Absolute paths of a figure's rendered assets, resolved against the agent.json directory. */
  figureAssets(id: string): Located[] {
    return ((this.figure(id)?.assets ?? []) as string[]).map((rel) => this.locate(rel));
  }

  /** The figure's data file (every plotted point; `data.path`), resolved to an absolute path, or null. */
  figureData(id: string): Located | null {
    const rel = this.figure(id)?.data?.path;
    return typeof rel === "string" ? this.locate(rel) : null;
  }

  private figure(id: string): any {
    const u = this.units.get(id);
    return u?.kind === "figure" ? u.node : undefined;
  }

  // A path the agent.json names, resolved against its directory and refused unless it stays inside
  // it once symlinks are followed: a registry ships agent.json files someone else wrote, and a path
  // must not reach the reader's other files. A file not written yet is judged by its path alone.
  private locate(rel: string): Located {
    const abs = resolve(this.baseDir, rel);
    const inside = existsSync(abs)
      ? within(realpathSync(this.baseDir), realpathSync(abs))
      : within(this.baseDir, abs);
    if (!inside) throw new Error(`refused '${rel}': it resolves outside the agent directory ${this.baseDir}`);
    return { rel, abs };
  }
}

/** Load an Atlas from an agent.json file, or from a directory that contains one. */
export function loadAtlas(agentPath: string): Atlas {
  const file = agentPath.endsWith(".json") ? agentPath : join(agentPath, "agent.json");
  const raw = JSON.parse(readFileSync(file, "utf8"));
  const doc = AgentDocZ.parse(raw);
  return new Atlas(doc, dirname(resolve(file)));
}
