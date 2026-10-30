// Atlas — a queryable index over ANY Pinax `agent.json`. Pure (no MCP, no I/O beyond the initial
// load), so it is usable as a plain library: `loadAtlas(path).search("...")`. The MCP server in
// server.ts is just one frontend over this.
//
// Every unit (part / page / section / figure) is addressable by its id — Pinax ids are globally
// unique within a document (they key the comment store), so a single id -> unit map is the index.
import { readFileSync } from "node:fs";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { AgentDocZ, type AgentDoc, type Part } from "./schema.js";

export type UnitKind = "part" | "page" | "section" | "text" | "figure" | "table" | "code" | "check";

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

export class Atlas {
  readonly doc: AgentDoc;
  /** Directory of the agent.json, used to resolve the relative asset paths it references. */
  readonly baseDir: string;
  private units = new Map<string, Unit>();
  private order: string[] = [];

  constructor(doc: AgentDoc, baseDir: string) {
    this.doc = doc;
    this.baseDir = baseDir;
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

  // A container's prose, figures, tables, code blocks and checks, each addressable under its id.
  private addLeaves(node: any, parent: string): void {
    for (const t of node.texts ?? []) {
      // a prose block's label is its first line (what a reader would recognise)
      this.add({ kind: "text", id: t.id, label: t.text.split("\n")[0], parent, node: t });
    }
    for (const fig of node.figures ?? []) {
      this.add({ kind: "figure", id: fig.id, label: fig.caption, parent, node: fig });
    }
    for (const tbl of node.tables ?? []) {
      this.add({ kind: "table", id: tbl.id, label: tbl.caption || tbl.id, parent, node: tbl });
    }
    for (const blk of node.codes ?? []) {
      // a code block's label is its caption, else its first line (what a reader would recognise)
      const label = blk.caption || blk.source.split("\n")[0];
      this.add({ kind: "code", id: blk.id, label, parent, node: blk });
    }
    for (const chk of node.checks ?? []) {
      this.add({ kind: "check", id: chk.id, label: chk.label, parent, node: chk });
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

  /** A token-lean text outline of the whole document, figures and tables in declaration order. */
  outline(): string {
    const out: string[] = [`# ${this.doc.title}`];
    // a container's verdict over its subtree ("" when it holds no checks — never a vacuous PASS)
    const verdictOf = (node: any): string =>
      node.verdict ? `  [${node.verdict.verdict} ${node.verdict.passed}/${node.verdict.total}]` : "";
    const partOf = new Map<string, Part>(this.doc.parts.map((p) => [p.id, p]));
    // walk a page/section's `content` (declaration order); fall back to figures-then-tables.
    const emitContent = (node: any): void => {
      const content = node.content as { kind: string; id: string }[] | undefined;
      if (content && content.length) {
        for (const { kind, id } of content) {
          if (kind === "section") continue; // a nested section gets its own heading, below
          const u = this.unit(id);
          // a check leads with its result, so a reader sees PASS/FAIL before the expression
          const label = !u ? "(missing)" : u.kind === "check" ? `${u.node.pass ? "PASS" : "FAIL"} ${u.label}` : u.label;
          // emit even an unresolvable id (stale agent.json) so it is visible, not silently dropped
          out.push(`- [${kind} ${id}] ${label}`);
        }
      } else {
        for (const f of node.figures ?? []) out.push(`- [figure ${f.id}] ${f.caption}`);
        for (const t of node.tables ?? []) out.push(`- [table ${t.id}] ${t.caption || t.id}`);
      }
    };
    let lastPart: string | null | undefined;
    for (const page of this.doc.pages) {
      const pid = page.part ?? null;
      if (pid !== (lastPart ?? null)) {
        lastPart = pid;
        if (pid) out.push(`\n## [part ${pid}] ${partOf.get(pid)?.title ?? pid}`);
      }
      const summary = page.summary ? ` — ${page.summary}` : "";
      const status = page.status && page.status !== "final" ? ` [status: ${page.status}]` : "";
      out.push(`\n### [page ${page.id}] ${page.title}${status}${summary}${verdictOf(page)}`);
      emitContent(page);
      // nested sections one heading level deeper per depth (a top-level section is ####)
      const emitSection = (sec: any, level: number): void => {
        out.push(`${"#".repeat(level)} [section ${sec.id}] ${sec.title}${verdictOf(sec)}`);
        emitContent(sec);
        for (const child of sec.sections ?? []) emitSection(child, level + 1);
      };
      for (const sec of page.sections) emitSection(sec, 4);
    }
    // what the build and the render recorded (a node a face left out, a failed figure), so a reader
    // sees the gaps rather than inferring them
    const diags = this.doc.diagnostics ?? [];
    if (diags.length) {
      out.push("\n## Diagnostics");
      for (const d of diags) out.push(`- [${d.severity}] ${d.item}: ${d.message}`);
    }
    return out.join("\n");
  }

  /** Case-insensitive substring search over labels, descriptions, summaries, code, and comments. */
  search(query: string): SearchHit[] {
    const q = query.toLowerCase();
    const hits: SearchHit[] = [];
    const consider = (u: Unit, field: string, text: string | null | undefined): void => {
      if (!text) return;
      const i = text.toLowerCase().indexOf(q);
      if (i < 0) return;
      const start = Math.max(0, i - 30);
      const slice = text.slice(start, i + q.length + 30).replace(/\s+/g, " ").trim();
      hits.push({
        id: u.id,
        kind: u.kind,
        label: u.label,
        field,
        snippet: (start > 0 ? "…" : "") + slice + (i + q.length + 30 < text.length ? "…" : ""),
      });
    };
    if (q.length === 0) return hits;
    for (const u of this.all()) {
      const n = u.node;
      consider(u, "label", u.label);
      if (u.kind === "figure") {
        consider(u, "code", n.code);
        if (typeof n.params === "string") consider(u, "params", n.params);
        for (const c of n.comments ?? []) consider(u, "comment", `${c.author}: ${c.text}`);
      } else if (u.kind === "code") {
        consider(u, "code", n.source);
      } else if (u.kind === "text") {
        consider(u, "text", n.text);
      } else if (u.kind === "table") {
        const cellStr = (c: unknown) => (c == null ? "" : String(c)); // avoid [object Object] / nested-array join
        consider(u, "cells", (n.rows ?? []).map((r: unknown[]) => r.map(cellStr).join(" ")).join(" | "));
      } else {
        consider(u, "desc", n.desc);
        if (u.kind === "page") consider(u, "summary", n.summary);
        for (const c of n.comments ?? []) consider(u, "comment", `${c.author}: ${c.text}`);
      }
    }
    return hits;
  }

  /** Absolute paths of a figure's rendered assets, resolved against the agent.json directory. */
  figureAssets(id: string): { rel: string; abs: string }[] {
    const u = this.units.get(id);
    if (!u || u.kind !== "figure") return [];
    return (u.node.assets as string[]).map((rel) => ({
      rel,
      abs: isAbsolute(rel) ? rel : resolve(this.baseDir, rel),
    }));
  }

  /** The figure's full plotted-data CSV (its `data` field), resolved to an absolute path, or null. */
  figureData(id: string): { rel: string; abs: string } | null {
    const u = this.units.get(id);
    if (!u || u.kind !== "figure" || typeof u.node.data !== "string") return null;
    const rel = u.node.data as string;
    return { rel, abs: isAbsolute(rel) ? rel : resolve(this.baseDir, rel) };
  }
}

/** Load an Atlas from an agent.json file, or from a directory that contains one. */
export function loadAtlas(agentPath: string): Atlas {
  const file = agentPath.endsWith(".json") ? agentPath : join(agentPath, "agent.json");
  const raw = JSON.parse(readFileSync(file, "utf8"));
  const doc = AgentDocZ.parse(raw);
  return new Atlas(doc, dirname(resolve(file)));
}
