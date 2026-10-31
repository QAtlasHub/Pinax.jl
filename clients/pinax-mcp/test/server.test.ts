// End-to-end: spawn the real stdio MCP server over the fixture and drive it with the SDK client,
// so the protocol layer (resources + tools) is exercised, not just the Atlas library.
import { test } from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { writeVariant } from "./variant.js";

const here = dirname(fileURLToPath(import.meta.url));
const serverEntry = resolve(here, "../src/index.js"); // dist/src/index.js
const fixture = resolve(here, "../../test/fixtures/sample");

async function withClient<T>(fn: (c: Client) => Promise<T>, agent = fixture): Promise<T> {
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [serverEntry, "--agent", agent],
  });
  const client = new Client({ name: "pinax-mcp-test", version: "0" }, { capabilities: {} });
  await client.connect(transport);
  try {
    return await fn(client);
  } finally {
    await client.close();
  }
}

const text = (r: any) => (r.content as any)[0].text;

test("tools list and run end-to-end over MCP (figures + tables)", { timeout: 20000 }, async () => {
  await withClient(async (client) => {
    const listed = (await client.listTools()).tools;
    assert.deepEqual(listed.map((t) => t.name).sort(), ["get_figure_data", "get_unit", "outline", "search"]);
    // every tool takes only the arguments it names
    for (const t of listed) assert.equal(t.inputSchema.additionalProperties, false, t.name);

    const outline = text(await client.callTool({ name: "outline", arguments: {} }));
    assert.match(outline, /Demo Atlas/);
    assert.match(outline, /\[table p1_tbl1\]/); // tables in the outline

    // a figure describes its data file; the points themselves come from get_figure_data
    const fig = JSON.parse(text(await client.callTool({ name: "get_unit", arguments: { id: "p1_fig1" } })));
    assert.equal(fig.caption, "magnetization vs temperature");
    assert.deepEqual(fig.data.columns, ["series", "T", "M"]);

    // a @table node is addressable the same way
    const tbl = JSON.parse(text(await client.callTool({ name: "get_unit", arguments: { id: "p1_tbl1" } })));
    assert.deepEqual(tbl.header, ["N", "Tc"]);

    // get_figure_data returns the full CSV behind the plot
    assert.match(text(await client.callTool({ name: "get_figure_data", arguments: { id: "p1_fig1" } })), /series,T,M/);
    // error path: a unit with no figure data (a @table) -> isError
    const noData = await client.callTool({ name: "get_figure_data", arguments: { id: "p1_tbl1" } });
    assert.equal(noData.isError, true);

    // search reaches table cells
    assert.match(text(await client.callTool({ name: "search", arguments: { query: "critical" } })), /p1_tbl1/);

    // each hit is its unit, then the field it matched and a snippet
    assert.equal(
      text(await client.callTool({ name: "search", arguments: { query: "critical" } })),
      "[table p1_tbl1] critical temperatures\n  label: critical temperatures",
    );
    assert.equal(text(await client.callTool({ name: "search", arguments: { query: "zzz" } })), "no matches for 'zzz'");

    const miss = await client.callTool({ name: "get_unit", arguments: { id: "nope" } });
    assert.equal(miss.isError, true);
    assert.equal(text(miss), "no unit with id 'nope'");

    const unknown = await client.callTool({ name: "no_such_tool", arguments: {} });
    assert.equal(unknown.isError, true);
    assert.equal(text(unknown), "unknown tool: no_such_tool");
  });
});

test("resources list and read end-to-end over MCP", { timeout: 20000 }, async () => {
  await withClient(async (client) => {
    const uris = (await client.listResources()).resources.map((r) => r.uri);
    assert.ok(uris.includes("pinax://document"));
    const docRes = (await client.listResources()).resources.find((r) => r.uri === "pinax://document");
    assert.equal(docRes?.name, "Demo Atlas"); // the document resource is named by its title
    assert.ok(uris.includes("pinax://figure/p1_fig1"));
    assert.ok(uris.includes("pinax://table/p1_tbl1")); // @table node listed as a resource

    const tbl = await client.readResource({ uri: "pinax://table/p1_tbl1" });
    const node = JSON.parse((tbl.contents[0] as any).text);
    assert.deepEqual(node.rows, [
      [8, 2.1],
      [16, 2.2],
      [32, 2.27],
    ]);

    // a rendered asset comes back with its mime; svg is textual
    const asset = await client.readResource({ uri: "pinax://asset/p1_fig1/0" });
    assert.equal((asset.contents[0] as any).mimeType, "image/svg+xml");
    assert.match((asset.contents[0] as any).text, /<svg/);
  });
});

test("a binary asset reads as base64; a bad resource uri is refused, saying why", { timeout: 20000 }, async () => {
  const dir = writeVariant((doc) => doc.pages[0].figures[0].assets.push("p1_fig1.png"));
  writeFileSync(join(dir, "p1_fig1.png"), Buffer.from([0x89, 0x50, 0x4e, 0x47]));
  await withClient(async (client) => {
    const png = (await client.readResource({ uri: "pinax://asset/p1_fig1/1" })).contents[0] as any;
    assert.equal(png.mimeType, "image/png");
    assert.equal(png.blob, Buffer.from([0x89, 0x50, 0x4e, 0x47]).toString("base64"));
    assert.equal(png.text, undefined);
    const refused = async (uri: string, why: RegExp) =>
      assert.rejects(client.readResource({ uri }), (e: Error) => why.test(e.message));
    await refused("pinax://asset/p1_fig1", /bad asset uri/);
    await refused("pinax://asset/p1_fig1/9", /no asset 9 for figure p1_fig1$/);
    await refused("pinax://figure/ghost", /unknown figure: ghost/);
    await refused("file:///etc/passwd", /unsupported resource uri/);
  }, dir);
});

test("get_figure_data and an asset read refuse a path outside the agent directory", { timeout: 20000 }, async () => {
  const secret = join(mkdtempSync(join(tmpdir(), "pinax-mcp-secret-")), "secret.txt");
  writeFileSync(secret, "zqsecret");
  const dir = writeVariant((doc) => {
    doc.pages[0].figures[0].data.path = secret;
    doc.pages[0].figures[0].assets = [secret];
  });
  await withClient(async (client) => {
    const data = await client.callTool({ name: "get_figure_data", arguments: { id: "p1_fig1" } });
    assert.equal(data.isError, true);
    assert.match(text(data), new RegExp(`'${secret}'.*outside the agent directory`));
    assert.doesNotMatch(text(data), /zqsecret/);
    await assert.rejects(client.readResource({ uri: "pinax://asset/p1_fig1/0" }), /outside the agent directory/);
  }, dir);
});

test("get_unit and a unit resource return the same node, indented two spaces", { timeout: 20000 }, async () => {
  await withClient(async (client) => {
    const tool = text(await client.callTool({ name: "get_unit", arguments: { id: "p1_tbl1" } }));
    const res = ((await client.readResource({ uri: "pinax://table/p1_tbl1" })).contents[0] as any).text;
    assert.equal(tool, res);
    assert.equal(tool, JSON.stringify(JSON.parse(tool), null, 2));
  });
});
