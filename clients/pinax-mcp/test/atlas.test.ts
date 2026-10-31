import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, relative } from "node:path";
import { loadAtlas } from "../src/atlas.js";
import { everyNodeVariant, sample as fixture, writeVariant } from "./variant.js";

test("indexes every unit by id and kind, including @table nodes", () => {
  const atlas = loadAtlas(fixture);
  assert.equal(atlas.doc.title, "Demo Atlas");
  assert.equal(atlas.unit("grp")?.kind, "part");
  assert.equal(atlas.unit("p1")?.kind, "page");
  assert.equal(atlas.unit("s1")?.kind, "section");
  assert.equal(atlas.unit("p1_fig1")?.kind, "figure");
  assert.equal(atlas.unit("p1_tbl1")?.kind, "table"); // @table node, addressable like a figure
  assert.equal(atlas.unit("p2_tbl1")?.kind, "table");
  assert.equal(atlas.unit("p1_tbl1")?.parent, "p1");
  assert.equal(atlas.unit("s1_fig1")?.parent, "s1");
  assert.equal(atlas.all("figure").length, 2);
  assert.equal(atlas.all("table").length, 2);
  // a table's label is its caption; header + native-typed rows are on the node
  assert.equal(atlas.unit("p1_tbl1")!.label, "critical temperatures");
  assert.deepEqual(atlas.unit("p1_tbl1")!.node.header, ["N", "Tc"]);
  assert.deepEqual(atlas.unit("p1_tbl1")!.node.rows, [
    [8, 2.1],
    [16, 2.2],
    [32, 2.27],
  ]);
});

test("a figure points at its data file and describes it exactly (no inlined copy)", () => {
  const fig = loadAtlas(fixture).unit("p1_fig1")!.node as any;
  assert.equal(fig.table, undefined);
  assert.match(fig.data.path, /p1_fig1\.csv$/);
  assert.deepEqual(fig.data.columns, ["series", "T", "M"]);
  assert.deepEqual(fig.data.series, [{ label: "N=8", points: 3 }]);
});

test("outline interleaves figures and tables in declaration order", () => {
  const o = loadAtlas(fixture).outline();
  assert.match(o, /^# Demo Atlas/);
  assert.match(o, /\[part grp\]/);
  assert.match(o, /\[page p1\] Page One — overview page/);
  // p1's content order is figure THEN table
  const fi = o.indexOf("[figure p1_fig1]");
  const ti = o.indexOf("[table p1_tbl1]");
  assert.ok(fi >= 0 && ti >= 0 && fi < ti);
  assert.match(o, /\[section s1\]/);
  assert.match(o, /\[table p2_tbl1\] a small table/);
});

test("outline puts a section where it stands in its container's content", () => {
  // a section written between two blocks is outlined between them, as every face reads it
  const dir = writeVariant((doc) => {
    const p1 = doc.pages.find((p: { id: string }) => p.id === "p1");
    p1.content = [p1.content[0], { kind: "section", id: "s1" }, ...p1.content.slice(1)];
  });
  const o = loadAtlas(dir).outline();
  const at = (s: string) => o.indexOf(s);
  assert.ok(at("[text p1_txt1]") < at("[section s1]"));
  assert.ok(at("[section s2]") < at("[figure p1_fig1]")); // s1's subtree, then the rest of p1
  assert.equal(o.split("[section s1]").length, 2); // once
});

test("search matches caption, code, comment, and table cells", () => {
  const atlas = loadAtlas(fixture);
  assert.ok(atlas.search("magnetization").some((h) => h.id === "p1_fig1" && h.field === "label"));
  assert.ok(atlas.search("converged").some((h) => h.id === "p1_fig1" && h.field === "comment"));
  assert.ok(atlas.search("critical").some((h) => h.id === "p1_tbl1" && h.field === "label"));
  assert.ok(atlas.search("2.27").some((h) => h.id === "p1_tbl1" && h.field === "cells")); // a cell value
  assert.equal(atlas.search("no-such-token-xyz").length, 0);
  assert.equal(atlas.search("").length, 0);
});

test("search reaches code, prose, raw html, and table, page and section comments", () => {
  const atlas = loadAtlas(everyNodeVariant());
  const found = (q: string) => atlas.search(q).map((h) => ({ id: h.id, kind: h.kind, field: h.field }));
  assert.deepEqual(found("zqcodetoken"), [{ id: "p1_code1", kind: "code", field: "code" }]);
  assert.deepEqual(found("zqtexttoken"), [{ id: "p1_txt1", kind: "text", field: "text" }]);
  assert.deepEqual(found("zqrawtoken"), [{ id: "p1_raw1", kind: "raw", field: "html" }]);
  assert.deepEqual(found("zqtablecomment"), [{ id: "p1_tbl1", kind: "table", field: "comment" }]);
  assert.deepEqual(found("zqpagecomment"), [{ id: "p1", kind: "page", field: "comment" }]);
  assert.deepEqual(found("zqsectioncomment"), [{ id: "s1", kind: "section", field: "comment" }]);
  // a comment hit reads "author: text"
  assert.equal(atlas.search("zqpagecomment")[0].snippet, "me: zqpagecomment");
});

test("a code block is labelled by its caption, else its first line; prose by its first line", () => {
  const atlas = loadAtlas(everyNodeVariant());
  assert.equal(atlas.unit("p1_code1")!.label, "first_line()");
  assert.equal(atlas.unit("p1_code2")!.label, "a captioned block");
  assert.equal(atlas.unit("p1_txt1")!.label, "headline");
  assert.equal(atlas.unit("p1_raw1")!.label, "<div>");
});

test("figure assets + full-data csv resolve to absolute paths", () => {
  const atlas = loadAtlas(fixture);
  const assets = atlas.figureAssets("p1_fig1");
  assert.equal(assets.length, 1); // the svg (the csv lives in `data`, not `assets`)
  assert.ok(assets[0].rel.endsWith("p1_fig1.svg"));
  const data = atlas.figureData("p1_fig1");
  assert.ok(data && data.abs.startsWith(atlas.baseDir) && data.abs.endsWith("p1_fig1.csv"));
  assert.equal(atlas.figureData("p1_tbl1"), null); // not a figure
});

test("nested sections are indexed to any depth, under their parent section", () => {
  const atlas = loadAtlas(fixture);
  assert.equal(atlas.unit("s2")?.kind, "section");
  assert.equal(atlas.unit("s2")?.parent, "s1");
  assert.equal(atlas.unit("s2")!.node.depth, 3);
});

test("checks are units, so a content reference to a check resolves", () => {
  const atlas = loadAtlas(fixture);
  const c = atlas.unit("s2_t1")!;
  assert.equal(c.kind, "check");
  assert.equal(c.parent, "s2");
  assert.equal(c.node.pass, false);
  assert.equal(atlas.all("check").length, 2);
});

test("outline shows each container's verdict, nested sections deeper, and checks", () => {
  const o = loadAtlas(fixture).outline();
  assert.match(o, /### \[page p1\] Page One — overview page {2}\[FAIL 1\/2\]/);
  assert.match(o, /#### \[section s1\] Section One {2}\[FAIL 1\/2\]/);
  assert.match(o, /##### \[section s2\] Section Two {2}\[FAIL 0\/1\]/);
  assert.match(o, /- \[check s1_t1\] PASS isapprox\(1\.0001, 1\.0; rtol = 0\.001\)/);
  assert.match(o, /- \[check s2_t1\] FAIL /);
  assert.doesNotMatch(o, /\(missing\)/);
  assert.doesNotMatch(o, /\[page p2\][^\n]*\[(PASS|FAIL)/); // no checks, no verdict
});


test("search reads a page's summary, a part's desc and a figure's string params and code", () => {
  const atlas = loadAtlas(
    writeVariant((doc) => {
      doc.pages[0].figures[0].params = "zqparams";
      doc.pages[0].sections[0].summary = "overview of a section";
    }),
  );
  const found = (q: string) => atlas.search(q).map((h) => `${h.id}.${h.field}`);
  assert.deepEqual(found("overview"), ["p1.summary"]); // a section's summary is not searched
  assert.deepEqual(found("group of"), ["grp.desc"]);
  assert.deepEqual(found("zqparams"), ["p1_fig1.params"]);
  assert.deepEqual(found("MF("), ["p1_fig1.code", "s1_fig1.code"]);
});

test("a search snippet is 30 characters either side, whitespace folded, cut ends marked", () => {
  const long = `${"a".repeat(40)}\n  zqmid  ${"b".repeat(40)}`;
  const atlas = loadAtlas(writeVariant((doc) => (doc.pages[0].summary = long)));
  const [hit] = atlas.search("zqmid");
  assert.equal(hit.snippet, `…${"a".repeat(27)} zqmid ${"b".repeat(28)}…`);
  const short = loadAtlas(writeVariant((doc) => (doc.pages[0].summary = "x zqmid y")));
  assert.equal(short.search("zqmid")[0].snippet, "x zqmid y");
  const one = `${"a".repeat(31)}zqmid`; // starts one character into the text: that one is cut
  assert.equal(loadAtlas(writeVariant((doc) => (doc.pages[0].summary = one))).search("zqmid")[0].snippet, `…${"a".repeat(30)}zqmid`);
  const edge = `zqmid${"b".repeat(30)}`; // ends exactly 30 characters after the match: nothing cut
  assert.equal(loadAtlas(writeVariant((doc) => (doc.pages[0].summary = edge))).search("zqmid")[0].snippet, edge);
});

test("table cells search as text: null is empty, a value is its string", () => {
  const atlas = loadAtlas(writeVariant((doc) => (doc.pages[0].tables[0].rows = [[null, "zq", 3]])));
  assert.equal(atlas.search("zq")[0].snippet, "zq 3");
});

test("outline: status, part headings, unresolvable refs, and the no-content fallback", () => {
  const o = loadAtlas(
    writeVariant((doc) => {
      const [p1, p2] = doc.pages;
      p1.content.push({ kind: "figure", id: "ghost" });
      p2.status = "draft";
      p2.part = "elsewhere";
      p2.content = [];
      p2.figures = [{ ...p1.figures[0], id: "p2_fig1", caption: "fallback figure" }];
      p2.tables[0].caption = "";
      doc.pages.push({ ...p2, id: "p3", title: "Page Three", part: null, status: "final" });
    }),
  ).outline();
  assert.match(o, /- \[figure ghost\] \(missing\)/);
  assert.match(o, /\n## \[part elsewhere\] elsewhere\n\n### \[page p2\] Page Two \[status: draft\]\n/);
  assert.match(o, /\[page p2\][^]*- \[figure p2_fig1\] fallback figure\n- \[table p2_tbl1\] p2_tbl1\n/);
  assert.match(o, /\n\n### \[page p3\] Page Three\n/); // no part: no part heading, no status
  assert.equal(o.split("[part grp]").length, 2); // one heading per run of pages in a part
});

// A file outside any agent directory, and a variant whose first figure's data and asset point at it
// by the path `point` returns.
function outsideVariant(point: (secret: string, dir: string) => string): string {
  const secret = join(mkdtempSync(join(tmpdir(), "pinax-mcp-secret-")), "secret.txt");
  writeFileSync(secret, "zqsecret");
  return writeVariant((doc, dir) => {
    const rel = point(secret, dir);
    doc.pages[0].figures[0].data.path = rel;
    doc.pages[0].figures[0].assets = [rel];
  });
}

test("a figure path that leaves the agent directory is refused, naming it", () => {
  const cases: [string, (secret: string, dir: string) => string][] = [
    ["..", (secret, dir) => relative(dir, secret)],
    ["absolute", (secret) => secret],
    [
      "symlink",
      (secret, dir) => {
        symlinkSync(secret, join(dir, "link.csv"));
        return "link.csv";
      },
    ],
  ];
  for (const [name, point] of cases) {
    const atlas = loadAtlas(outsideVariant(point));
    const rel = atlas.unit("p1_fig1")!.node.data.path as string;
    const named = (e: Error) => e.message.includes(`'${rel}'`) && /outside the agent directory/.test(e.message);
    assert.throws(() => atlas.figureData("p1_fig1"), named, name);
    assert.throws(() => atlas.figureAssets("p1_fig1"), named, name);
  }
});

test("a symlink to a file inside the agent directory, or a file not yet written, is located", () => {
  const atlas = loadAtlas(
    writeVariant((doc, dir) => {
      writeFileSync(join(dir, "real.csv"), "series,T,M\n");
      symlinkSync(join(dir, "real.csv"), join(dir, "link.csv"));
      doc.pages[0].figures[0].data.path = "link.csv";
      doc.pages[0].figures[0].assets = ["not-rendered.svg"];
    }),
  );
  assert.equal(readFileSync(atlas.figureData("p1_fig1")!.abs, "utf8"), "series,T,M\n");
  assert.equal(atlas.figureAssets("p1_fig1")[0].abs, join(atlas.baseDir, "not-rendered.svg"));
});
