// The MCP frontend over an Atlas. Generic: it exposes whatever units the agent.json contains.
//
//   resources  pinax://document                     the outline (text)
//              pinax://{kind}/{id}                   any unit: a part, page or section, or a text,
//                                                    figure, table, code, check or raw node (JSON)
//              pinax://asset/{figureId}/{index}      a figure's rendered asset (image/pdf bytes)
//   tools      outline()                             the document tree, token-lean
//              get_unit(id)                           one unit; a figure -> its verification substrate
//              search(query)                          substring search -> matching unit ids + snippet
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListResourcesRequestSchema,
  ListResourceTemplatesRequestSchema,
  ListToolsRequestSchema,
  ReadResourceRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { readFileSync } from "node:fs";
import { extname } from "node:path";
import type { Atlas, SearchHit, Unit } from "./atlas.js";
import type { CommentStore } from "./comments.js";

const MIME: Record<string, string> = {
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".avif": "image/avif",
  ".pdf": "application/pdf",
  ".json": "application/json",
};
// The unit kinds every Pinax face shows comments on; a comment on any other kind would be stored and
// shown nowhere (Conventions › Faces), so add_comment refuses it.
const COMMENT_CARRIERS = new Set(["page", "section", "figure", "table"]);
// The gallery shows a bookmark on a section only, so set_bookmark refuses every other kind.
const BOOKMARK_CARRIERS = new Set(["section"]);

const mimeFor = (p: string): string => MIME[extname(p).toLowerCase()] ?? "application/octet-stream";
const isTextual = (m: string): boolean =>
  m.startsWith("text/") || m === "image/svg+xml" || m === "application/json";

export interface ServerOptions {
  name?: string;
  version?: string;
  /** When set, the write tools (add_comment / set_bookmark) are exposed. */
  store?: CommentStore;
}

// ---- resources ------------------------------------------------------------------------------

const RESOURCE_TEMPLATES = [
  { uriTemplate: "pinax://figure/{id}", name: "Figure by id", mimeType: "application/json" },
  { uriTemplate: "pinax://page/{id}", name: "Page by id", mimeType: "application/json" },
  { uriTemplate: "pinax://section/{id}", name: "Section by id", mimeType: "application/json" },
  { uriTemplate: "pinax://part/{id}", name: "Part by id", mimeType: "application/json" },
  { uriTemplate: "pinax://table/{id}", name: "Table (@table node) by id", mimeType: "application/json" },
  { uriTemplate: "pinax://asset/{figureId}/{index}", name: "A figure's rendered asset" },
];

const listResources = (atlas: Atlas) => [
  {
    uri: "pinax://document",
    name: atlas.doc.title || "document",
    description: "The document outline (parts, pages, sections, figures).",
    mimeType: "text/markdown",
  },
  ...atlas.all().map((u) => ({
    uri: `pinax://${u.kind}/${u.id}`,
    name: `${u.kind}: ${u.label}`,
    mimeType: "application/json",
  })),
];

function readResource(atlas: Atlas, uri: string) {
  if (uri === "pinax://document") {
    return { contents: [{ uri, mimeType: "text/markdown", text: atlas.outline() }] };
  }
  const m = uri.match(/^pinax:\/\/([a-z]+)\/(.+)$/);
  if (!m) throw new Error(`unsupported resource uri: ${uri}`);
  const [, kind, rest] = m;
  return kind === "asset" ? readAsset(atlas, uri, rest) : readUnit(atlas, uri, kind, rest);
}

// pinax://asset/{figureId}/{index}: the bytes of a figure's rendered asset, as text when textual
function readAsset(atlas: Atlas, uri: string, rest: string) {
  const am = rest.match(/^(.+)\/(\d+)$/);
  if (!am) throw new Error(`bad asset uri (want pinax://asset/{figureId}/{index}): ${uri}`);
  const a = atlas.figureAssets(am[1])[Number(am[2])];
  if (!a) throw new Error(`no asset ${am[2]} for figure ${am[1]}`);
  const mimeType = mimeFor(a.abs);
  const buf = readFileSync(a.abs);
  const body = isTextual(mimeType) ? { text: buf.toString("utf8") } : { blob: buf.toString("base64") };
  return { contents: [{ uri, mimeType, ...body }] };
}

// a unit's agent.json node, verbatim, as a resource read and get_unit return it
const unitJson = (u: Unit): string => JSON.stringify(u.node, null, 2);

function readUnit(atlas: Atlas, uri: string, kind: string, id: string) {
  const u = atlas.unit(id);
  if (!u) throw new Error(`unknown ${kind}: ${id}`);
  return { contents: [{ uri, mimeType: "application/json", text: unitJson(u) }] };
}

// ---- tools ----------------------------------------------------------------------------------

type Args = Record<string, unknown>;
type Reply = { content: { type: "text"; text: string }[]; isError?: boolean };
interface Context {
  atlas: Atlas;
  store?: CommentStore;
}
interface Tool {
  name: string;
  description: string;
  inputSchema: { type: "object"; [k: string]: unknown };
  run: (ctx: Context, args: Args) => Reply;
}

const ok = (text: string): Reply => ({ content: [{ type: "text", text }] });
const err = (text: string): Reply => ({ content: [{ type: "text", text }], isError: true });
// A string argument, or `fallback` when it is absent; any other value is refused, never coerced.
function str(args: Args, key: string, fallback = ""): string {
  const v = args[key];
  if (v === undefined) return fallback;
  if (typeof v !== "string") throw new Error(`'${key}' must be a string, not ${JSON.stringify(v)}`);
  return v;
}
const inputs = (properties: object, required: string[] = []) => ({
  type: "object" as const,
  properties,
  ...(required.length ? { required } : {}),
  additionalProperties: false,
});
const disabled = (tool: string): Reply => err(`${tool} is disabled: start the server with --comments <path>`);

// The error reply when `id` names no unit, or one whose kind is not in `kinds` (`why` says so).
function refusal(atlas: Atlas, id: string, kinds: Set<string>, why: (u: Unit) => string): Reply | null {
  const u = atlas.unit(id);
  if (!u) return err(`no unit with id '${id}' in this document`);
  return kinds.has(u.kind) ? null : err(why(u));
}

const formatHit = (h: SearchHit): string => `[${h.kind} ${h.id}] ${h.label}\n  ${h.field}: ${h.snippet}`;

const READ_TOOLS: Tool[] = [
  {
    name: "outline",
    description:
      "Token-lean text outline of the whole document (parts -> pages -> sections -> every node, in reading order, each with its id).",
    inputSchema: inputs({}),
    run: ({ atlas }) => ok(atlas.outline()),
  },
  {
    name: "get_unit",
    description:
      "Fetch one unit by its id. A figure returns what it claims and what is behind it: caption, where it was defined, generating code, params, image paths, comments, and its data file described exactly (path, columns, points per series) — read the file with get_figure_data. A table returns its header + native-typed rows.",
    inputSchema: inputs({ id: { type: "string", description: "the unit id, e.g. a figure or table id" } }, ["id"]),
    run: ({ atlas }, a) => {
      const u = atlas.unit(str(a, "id"));
      return u ? ok(unitJson(u)) : err(`no unit with id '${str(a, "id")}'`);
    },
  },
  {
    name: "search",
    description:
      "Case-insensitive substring search across titles, captions, descriptions, generating code, comments, and table cells. Returns matching unit ids with a snippet.",
    inputSchema: inputs({ query: { type: "string" } }, ["query"]),
    run: ({ atlas }, a) => {
      const hits = atlas.search(str(a, "query"));
      return ok(hits.length ? hits.map(formatHit).join("\n") : `no matches for '${str(a, "query")}'`);
    },
  },
  {
    name: "get_figure_data",
    description:
      "Read a figure's data file: every plotted point as CSV, the columns named by the plot's axis labels. Returns the CSV text.",
    inputSchema: inputs({ id: { type: "string", description: "a figure id" } }, ["id"]),
    run: ({ atlas }, a) => {
      const d = atlas.figureData(str(a, "id"));
      return d ? ok(readFileSync(d.abs, "utf8")) : err(`no data CSV for figure '${str(a, "id")}'`);
    },
  },
];

// The write tools mutate the comment store, so they are exposed only when one is configured.
const WRITE_TOOLS: Tool[] = [
  {
    name: "add_comment",
    description:
      "Append a comment to a page, section, figure or table (by id) in the Pinax comment store (comments.toml); every face shows comments on those kinds only. The agent end of the comment loop: the note is written durably; re-render the document to bake it into the gallery / agent.json.",
    inputSchema: inputs(
      {
        id: { type: "string", description: "the unit id to comment on" },
        text: { type: "string", description: "the comment body (markdown)" },
        author: { type: "string", description: "who is commenting (default 'llm')" },
      },
      ["id", "text"],
    ),
    run: addComment,
  },
  {
    name: "set_bookmark",
    description:
      "Mark or unmark a section (by id) as bookmarked in the comment store; the gallery shows bookmarks on sections only.",
    inputSchema: inputs({ id: { type: "string" }, on: { type: "boolean", description: "default true" } }, ["id"]),
    run: setBookmark,
  },
];

function addComment({ atlas, store }: Context, a: Args): Reply {
  if (!store) return disabled("add_comment");
  const id = str(a, "id");
  const text = str(a, "text");
  const author = str(a, "author", "llm");
  if (!id || !text) return err("add_comment requires 'id' and 'text'");
  const refused = refusal(
    atlas,
    id,
    COMMENT_CARRIERS,
    (u) =>
      `a comment on a ${u.kind} is shown nowhere: comment on a page, section, figure or table (the ${u.kind}'s container is '${u.parent ?? ""}')`,
  );
  if (refused) return refused;
  const turns = store.addComment(id, text, author);
  return ok(
    `comment added to '${id}' (now ${turns.length} turn(s)). Re-render the document to bake it into the gallery / agent.json.`,
  );
}

function setBookmark({ atlas, store }: Context, a: Args): Reply {
  if (!store) return disabled("set_bookmark");
  const id = str(a, "id");
  if (!id) return err("set_bookmark requires 'id'");
  const refused = refusal(
    atlas,
    id,
    BOOKMARK_CARRIERS,
    (u) => `a bookmark on a ${u.kind} is shown nowhere: the gallery bookmarks sections only`,
  );
  if (refused) return refused;
  if (a.on !== undefined && typeof a.on !== "boolean")
    return err(`set_bookmark: 'on' must be a boolean, not ${JSON.stringify(a.on)}`);
  const on = a.on ?? true;
  store.setBookmark(id, on);
  return ok(`bookmark for '${id}' set to ${on}.`);
}

// Every tool runs by name; a write tool called without a store says it is disabled.
function callTool(ctx: Context, name: string, args: Args | undefined): Reply {
  const tool = [...READ_TOOLS, ...WRITE_TOOLS].find((t) => t.name === name);
  if (!tool) return err(`unknown tool: ${name}`);
  try {
    return tool.run(ctx, args ?? {});
  } catch (e) {
    return err(`error: ${(e as Error).message}`);
  }
}

const listTools = (store?: CommentStore) =>
  [...READ_TOOLS, ...(store ? WRITE_TOOLS : [])].map(({ run, ...def }) => def);

export function createServer(atlas: Atlas, opts: ServerOptions = {}): Server {
  const server = new Server(
    { name: opts.name ?? "pinax-mcp", version: opts.version ?? "0.1.0" },
    { capabilities: { resources: {}, tools: {} } },
  );
  const ctx: Context = { atlas, store: opts.store };
  server.setRequestHandler(ListResourcesRequestSchema, async () => ({ resources: listResources(atlas) }));
  server.setRequestHandler(ListResourceTemplatesRequestSchema, async () => ({
    resourceTemplates: RESOURCE_TEMPLATES,
  }));
  server.setRequestHandler(ReadResourceRequestSchema, async (req) => readResource(atlas, req.params.uri));
  server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: listTools(opts.store) }));
  server.setRequestHandler(CallToolRequestSchema, async (req) =>
    callTool(ctx, req.params.name, req.params.arguments),
  );
  return server;
}

/** Connect a server over stdio (the standard MCP transport for a local subprocess). */
export async function serveStdio(atlas: Atlas, opts: ServerOptions = {}): Promise<void> {
  const server = createServer(atlas, opts);
  await server.connect(new StdioServerTransport());
}
