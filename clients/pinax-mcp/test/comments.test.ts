import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parse } from "smol-toml";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { CommentStore } from "../src/comments.js";
import { everyNodeVariant } from "./variant.js";

const tmpToml = (): string => join(mkdtempSync(join(tmpdir(), "pinax-mcp-")), "comments.toml");

// ---- CommentStore: byte-compatible with Pinax.read_comments / Pinax.add_comment ----

test("addComment appends id-keyed array-of-tables (the shape read_comments expects)", () => {
  const path = tmpToml();
  const store = new CommentStore(path);
  store.addComment("eq_energy", "first note", "llm");
  store.addComment("eq_energy", "second note", "sensei");
  store.addComment("p1_fig1", "other unit", "llm");

  const data = parse(readFileSync(path, "utf8")) as any;
  assert.equal(data.comment.eq_energy.length, 2);
  // smol-toml >= 1.9 parses tables as null-prototype objects; compare the fields, not the prototype
  assert.deepEqual({ ...data.comment.eq_energy[0] }, { author: "llm", text: "first note" });
  assert.deepEqual({ ...data.comment.eq_energy[1] }, { author: "sensei", text: "second note" });
  assert.equal(data.comment.p1_fig1.length, 1);
});

test("appends are preserved across store instances (append-only, multi-writer)", () => {
  const path = tmpToml();
  new CommentStore(path).addComment("s1", "a", "x");
  const turns = new CommentStore(path).addComment("s1", "b", "y"); // fresh instance, same file
  assert.deepEqual(turns, [
    { author: "x", text: "a" },
    { author: "y", text: "b" },
  ]);
});

test("text with quotes/backslash/newline round-trips (TOML escaping handled)", () => {
  const path = tmpToml();
  const store = new CommentStore(path);
  const tricky = 'has "quotes", a \\backslash and\na newline';
  store.addComment("fig", tricky, "llm");
  assert.equal(store.comments("fig")[0].text, tricky);
  assert.equal((parse(readFileSync(path, "utf8")) as any).comment.fig[0].text, tricky);
});

test("setBookmark writes the [bookmark] table next to comments", () => {
  const path = tmpToml();
  const store = new CommentStore(path);
  store.addComment("fig", "n", "llm");
  store.setBookmark("fig", true);
  const data = parse(readFileSync(path, "utf8")) as any;
  assert.equal(data.bookmark.fig, true);
  assert.equal(data.comment.fig.length, 1);
});

test("a turn's author and text read as Pinax.read_comments reads them: any value as its text", () => {
  const path = tmpToml();
  writeFileSync(path, "[[comment.fig]]\nauthor = false\ntext = 0\n");
  assert.deepEqual(new CommentStore(path).comments("fig"), [{ author: "false", text: "0" }]);
});

test("a missing store is non-fatal (empty)", () => {
  const store = new CommentStore(join(tmpdir(), "pinax-mcp-nope-xyz", "c.toml"));
  assert.deepEqual(store.comments("any"), []);
});

test("a write creates the store's missing directories, an existing one is reused", () => {
  const root = mkdtempSync(join(tmpdir(), "pinax-mcp-mkdir-"));
  const path = join(root, "out", "agent", "comments.toml"); // two levels not there yet
  const store = new CommentStore(path);
  store.addComment("fig", "first", "llm");
  store.setBookmark("fig", true); // the directory now exists: written to, not refused
  const data = parse(readFileSync(path, "utf8")) as any;
  assert.deepEqual({ ...data.comment.fig[0] }, { author: "llm", text: "first" });
  assert.equal(data.bookmark.fig, true);
});

test("a store that does not parse is never overwritten: a write refuses, naming the file", () => {
  const dir = mkdtempSync(join(tmpdir(), "pinax-mcp-bad-"));
  const path = join(dir, "comments.toml");
  const bad = '[[comment.fig]]\nauthor = "me"\ntext = "unterminated\n';
  writeFileSync(path, bad);
  const store = new CommentStore(path);
  assert.deepEqual(store.comments("fig"), []); // a read sees nothing it can trust
  assert.throws(() => store.addComment("fig", "new"), /comments\.toml.*does not parse/);
  assert.throws(() => store.setBookmark("fig", true), /does not parse/);
  assert.equal(readFileSync(path, "utf8"), bad); // what a person wrote is still there
});

test("a [comment.x] single table is not appended to: a write refuses, saying the shape", () => {
  const path = join(mkdtempSync(join(tmpdir(), "pinax-mcp-shape-")), "comments.toml");
  writeFileSync(path, '[comment.fig]\nauthor = "me"\ntext = "one table"\n');
  assert.throws(() => new CommentStore(path).addComment("fig", "new"), /\[\[comment\.fig\]\]/);
});

// ---- end-to-end: the write tool over MCP, gated on --comments ----

const here = dirname(fileURLToPath(import.meta.url));
const serverEntry = resolve(here, "../src/index.js");
const fixture = resolve(here, "../../test/fixtures/sample");

test("add_comment is exposed only with --comments and persists over MCP", { timeout: 20000 }, async () => {
  const cf = tmpToml();
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [serverEntry, "--agent", fixture, "--comments", cf],
  });
  const client = new Client({ name: "pinax-mcp-test", version: "0" }, { capabilities: {} });
  await client.connect(transport);
  try {
    const tools = (await client.listTools()).tools.map((t) => t.name);
    assert.ok(tools.includes("add_comment"));
    assert.ok(tools.includes("set_bookmark"));

    const res = await client.callTool({
      name: "add_comment",
      arguments: { id: "p1_fig1", text: "verified", author: "llm" },
    });
    assert.match((res.content as any)[0].text, /comment added to 'p1_fig1'/);

    // commenting on an id not in the document is rejected
    const bad = await client.callTool({ name: "add_comment", arguments: { id: "ghost", text: "x" } });
    assert.equal(bad.isError, true);
    const noText = await client.callTool({ name: "add_comment", arguments: { id: "p1_fig1" } });
    assert.match((noText.content as any)[0].text, /add_comment requires 'id' and 'text'/);

    // a table carries comments; a check does not (no face would show it), so it is refused
    const tbl = await client.callTool({ name: "add_comment", arguments: { id: "p1_tbl1", text: "ok" } });
    assert.match((tbl.content as any)[0].text, /comment added to 'p1_tbl1'/);
    const chk = await client.callTool({ name: "add_comment", arguments: { id: "s1_t1", text: "x" } });
    assert.equal(chk.isError, true);
    assert.match((chk.content as any)[0].text, /shown nowhere.*'s1'/);
  } finally {
    await client.close();
  }

  // the file is now a Pinax-compatible comments.toml
  const data = parse(readFileSync(cf, "utf8")) as any;
  assert.deepEqual({ ...data.comment.p1_fig1[0] }, { author: "llm", text: "verified" }); // null-prototype table
});

test("without --comments the write tools are absent (read-only by default)", { timeout: 20000 }, async () => {
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [serverEntry, "--agent", fixture],
  });
  const client = new Client({ name: "pinax-mcp-test", version: "0" }, { capabilities: {} });
  await client.connect(transport);
  try {
    const tools = (await client.listTools()).tools.map((t) => t.name);
    assert.ok(!tools.includes("add_comment"));
  } finally {
    await client.close();
  }
});

test("set_bookmark marks a section or a figure, and 'on' must be a boolean", { timeout: 20000 }, async () => {
  const cf = tmpToml();
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [serverEntry, "--agent", fixture, "--comments", cf],
  });
  const client = new Client({ name: "pinax-mcp-test", version: "0" }, { capabilities: {} });
  await client.connect(transport);
  const call = (args: Record<string, unknown>) => client.callTool({ name: "set_bookmark", arguments: args });
  const bookmarks = () => ({ ...(parse(readFileSync(cf, "utf8")) as any).bookmark });
  try {
    // a section is bookmarked (the default is on), and unbookmarked with on: false
    const on = await call({ id: "s1" });
    assert.match((on.content as any)[0].text, /bookmark for 's1' set to true/);
    assert.deepEqual(bookmarks(), { s1: true });
    await call({ id: "s1", on: false });
    assert.deepEqual(bookmarks(), { s1: false });

    // a figure's bookmark picks its page's card thumbnail, so it is accepted
    assert.match((await call({ id: "p1_fig1" }).then((r) => (r.content as any)[0].text)), /set to true/);
    // any other kind is shown nowhere: refused, naming the kind
    for (const [id, kind] of [
      ["p1", "page"],
      ["p1_tbl1", "table"],
    ]) {
      const res = await call({ id });
      assert.equal(res.isError, true, id);
      assert.match((res.content as any)[0].text, new RegExp(`on a ${kind}`), id);
    }

    assert.match(((await call({})).content as any)[0].text, /set_bookmark requires 'id'/);
    const ghost = await call({ id: "ghost" });
    assert.match((ghost.content as any)[0].text, /no unit with id 'ghost'/);

    // a string is not a boolean: "false" must not set the bookmark
    const str = await call({ id: "s1", on: "false" });
    assert.equal(str.isError, true);
    assert.match((str.content as any)[0].text, /'on' must be a boolean/);
    assert.deepEqual(bookmarks(), { s1: false, p1_fig1: true });
  } finally {
    await client.close();
  }
});

test("add_comment takes a page and a section, and refuses what no face shows a comment on", { timeout: 20000 }, async () => {
  const cf = tmpToml();
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [serverEntry, "--agent", everyNodeVariant(), "--comments", cf],
  });
  const client = new Client({ name: "pinax-mcp-test", version: "0" }, { capabilities: {} });
  await client.connect(transport);
  const comment = (id: string) => client.callTool({ name: "add_comment", arguments: { id, text: "n" } });
  try {
    for (const id of ["p1", "s1"]) {
      const res = await comment(id);
      assert.equal(res.isError, undefined, id);
      assert.match((res.content as any)[0].text, new RegExp(`comment added to '${id}'`));
    }
    for (const [id, kind] of [
      ["grp", "part"],
      ["p1_txt1", "text"],
      ["p1_code1", "code"],
      ["p1_raw1", "raw"],
    ]) {
      const res = await comment(id);
      assert.equal(res.isError, true, id);
      assert.match((res.content as any)[0].text, new RegExp(`a comment on a ${kind} is shown nowhere`), id);
    }
  } finally {
    await client.close();
  }
  const data = parse(readFileSync(cf, "utf8")) as any;
  assert.deepEqual(Object.keys(data.comment).sort(), ["p1", "s1"]);
});

test("a non-string id, text, author or query is refused, never coerced", { timeout: 20000 }, async () => {
  const cf = tmpToml();
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [serverEntry, "--agent", fixture, "--comments", cf],
  });
  const client = new Client({ name: "pinax-mcp-test", version: "0" }, { capabilities: {} });
  await client.connect(transport);
  const refused = async (name: string, args: Record<string, unknown>, key: string, shown: string) => {
    const res = await client.callTool({ name, arguments: args });
    assert.equal(res.isError, true, `${name} ${key}`);
    assert.match((res.content as any)[0].text, new RegExp(`'${key}' must be a string, not ${shown}`));
  };
  try {
    await refused("add_comment", { id: { x: 1 }, text: "n" }, "id", '\\{"x":1\\}');
    await refused("add_comment", { id: "p1_fig1", text: 5 }, "text", "5");
    await refused("add_comment", { id: "p1_fig1", text: "n", author: null }, "author", "null");
    await refused("set_bookmark", { id: ["s1"] }, "id", '\\["s1"\\]');
    await refused("get_unit", { id: 5 }, "id", "5");
    await refused("get_figure_data", { id: true }, "id", "true");
    await refused("search", { query: 2 }, "query", "2");
  } finally {
    await client.close();
  }
  assert.throws(() => readFileSync(cf, "utf8"), /ENOENT/); // nothing was written
});
