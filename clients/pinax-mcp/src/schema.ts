// The Pinax `agent.json` contract, as a runtime-validated schema. This is the ONLY thing the server
// depends on — it consumes any document emitted by `render(theme=:agent)`, never a specific gallery.
//
// `.passthrough()` everywhere so a future Pinax that adds a field (e.g. a format version) still parses
// against this older consumer. Param values are scalars today (the agent emitter writes JSON numbers /
// bools / strings); `params` itself is the three shapes the emitter can produce: a structured axis
// object, a string fallback (opaque params), or null.
import { z } from "zod";

export const ParamScalar = z.union([z.string(), z.number(), z.boolean()]);
export const Params = z.union([z.null(), z.string(), z.record(z.string(), ParamScalar)]);

export const CommentZ = z.object({ author: z.string(), text: z.string() }).passthrough();

// A content-order reference — {kind: "figure"|"table"|..., id} in declaration order.
export const ContentRefZ = z.object({ kind: z.string(), id: z.string() }).passthrough();

// A @table node — first-class tabular data, id-addressable like a figure.
export const TableNodeZ = z
  .object({
    id: z.string(),
    caption: z.string(),
    defined_at: z.string().optional(), // where the @table was written, "path:line", or ""
    code: z.string(),
    header: z.array(z.string()),
    rows: z.array(z.array(z.unknown())),
    comments: z.array(CommentZ).optional(), // the table's own thread, as a figure carries one
  })
  .passthrough();

// A figure's data file, described exactly: the path, its columns (the series label, then the x and y
// axes named by the plot's axis labels) and each series with its point count. The file holds every
// plotted point; nothing of it is inlined (Conventions › The agent face).
export const FigureDataZ = z
  .object({
    path: z.string(),
    columns: z.array(z.string()),
    series: z.array(z.object({ label: z.string(), points: z.number() }).passthrough()),
  })
  .passthrough();

export const FigureZ = z
  .object({
    id: z.string(),
    caption: z.string(),
    defined_at: z.string().optional(), // where the @figure was written, "path:line", or ""
    code: z.string(),
    params: Params,
    assets: z.array(z.string()),
    data: FigureDataZ.nullable().optional(), // null when the figure has no data form
    comments: z.array(CommentZ),
  })
  .passthrough();

// A `@code` block (or the code a `@test` was captured from): what ran, and what it printed.
export const CodeZ = z
  .object({
    id: z.string(),
    caption: z.string().optional(),
    defined_at: z.string().optional(), // where the block was written, "path:line", or ""
    lang: z.string(),
    source: z.string(),
    output: z.string(),
  })
  .passthrough();

// A prose block (`@desc`): markdown and math, placed in content order like any other node.
export const TextZ = z.object({ id: z.string(), text: z.string() }).passthrough();

// A `@raw` block: author-written HTML, as written (what the gallery shows verbatim).
export const RawZ = z.object({ id: z.string(), html: z.string() }).passthrough();

// A number, or the string a non-finite value is written as ("NaN", "Inf").
const NumZ = z.union([z.number(), z.string()]);

// One check — a `Test` `@test` recorded into a container, with what it compared and its margin.
export const CheckZ = z
  .object({
    id: z.string(),
    label: z.string(),
    got: NumZ,
    want: NumZ,
    delta: NumZ,
    tol: NumZ,
    kind: z.string(),
    pass: z.boolean(),
    source: z.string().optional(),
    code_id: z.string().nullable().optional(), // the code block it was captured from, by id
  })
  .passthrough();

// A container's verdict over its whole subtree; `null` when the subtree holds no checks.
export const VerdictZ = z
  .object({
    verdict: z.enum(["PASS", "FAIL"]),
    passed: z.number(),
    total: z.number(),
    failed: z.array(z.string()),
  })
  .passthrough();

// Sections nest to any depth: `depth` counts from the part (a page is 1, a top-level section 2).
export interface SectionT {
  id: string;
  title: string;
  depth?: number;
  summary?: string;
  verdict?: z.infer<typeof VerdictZ> | null;
  texts?: z.infer<typeof TextZ>[];
  figures: z.infer<typeof FigureZ>[];
  tables?: z.infer<typeof TableNodeZ>[];
  codes?: z.infer<typeof CodeZ>[];
  raws?: z.infer<typeof RawZ>[];
  checks?: z.infer<typeof CheckZ>[];
  content?: z.infer<typeof ContentRefZ>[];
  comments?: z.infer<typeof CommentZ>[];
  sections?: SectionT[];
  [k: string]: unknown;
}
export const SectionZ: z.ZodType<SectionT> = z.lazy(() =>
  z
    .object({
      id: z.string(),
      title: z.string(),
      depth: z.number().optional(),
      summary: z.string().optional(),
      verdict: VerdictZ.nullable().optional(),
      texts: z.array(TextZ).optional(),
      figures: z.array(FigureZ),
      tables: z.array(TableNodeZ).optional(),
      codes: z.array(CodeZ).optional(),
      raws: z.array(RawZ).optional(),
      checks: z.array(CheckZ).optional(),
      content: z.array(ContentRefZ).optional(),
      comments: z.array(CommentZ).optional(), // the section's own thread, as a figure carries one
      sections: z.array(SectionZ).optional(),
    })
    .passthrough(),
);

export const PageZ = z
  .object({
    id: z.string(),
    title: z.string(),
    depth: z.number().optional(),
    part: z.string().nullable(),
    status: z.string().optional(), // maturity: "draft" (a manuscript) or "final" (the published version)
    summary: z.string().nullable().optional(),
    texts: z.array(TextZ).optional(),
    figures: z.array(FigureZ),
    tables: z.array(TableNodeZ).optional(),
    codes: z.array(CodeZ).optional(),
    raws: z.array(RawZ).optional(),
    verdict: VerdictZ.nullable().optional(),
    checks: z.array(CheckZ).optional(),
    content: z.array(ContentRefZ).optional(),
    comments: z.array(CommentZ).optional(), // the page's own thread, as a figure carries one
    sections: z.array(SectionZ),
  })
  .passthrough();

export const PartZ = z
  .object({
    id: z.string(),
    title: z.string(),
    desc: z.string().nullable(),
    status: z.string().nullable().optional(), // the default status of its pages, or null
  })
  .passthrough();

// What the build and the render recorded: a node a face left out, a figure that failed, …
export const DiagnosticZ = z
  .object({ severity: z.string(), item: z.string(), message: z.string() })
  .passthrough();

export const AgentDocZ = z
  .object({
    title: z.string(),
    parts: z.array(PartZ),
    pages: z.array(PageZ),
    diagnostics: z.array(DiagnosticZ).optional(),
  })
  .passthrough();

export type Figure = z.infer<typeof FigureZ>;
export type Text = z.infer<typeof TextZ>;
export type Code = z.infer<typeof CodeZ>;
export type Check = z.infer<typeof CheckZ>;
export type Verdict = z.infer<typeof VerdictZ>;
export type TableNode = z.infer<typeof TableNodeZ>;
export type ContentRef = z.infer<typeof ContentRefZ>;
export type Section = SectionT;
export type Page = z.infer<typeof PageZ>;
export type Part = z.infer<typeof PartZ>;
export type Diagnostic = z.infer<typeof DiagnosticZ>;
export type AgentDoc = z.infer<typeof AgentDocZ>;
