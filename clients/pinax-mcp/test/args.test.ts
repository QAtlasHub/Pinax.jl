import { test } from "node:test";
import assert from "node:assert/strict";
import { parseArgs } from "../src/args.js";

test("parseArgs reads --agent / -a and --comments, each with its value", () => {
  assert.deepEqual(parseArgs(["--agent", "out", "--comments", "c.toml"], {}), { agent: "out", comments: "c.toml" });
  assert.deepEqual(parseArgs(["-a", "out"], {}), { agent: "out", comments: undefined });
});

test("parseArgs: a flag with no value leaves the setting as it was; another argument sets nothing", () => {
  const env = { PINAX_AGENT: "from-env", PINAX_COMMENTS: "env.toml" };
  assert.deepEqual(parseArgs(["--agent"], env), { agent: "from-env", comments: "env.toml" });
  assert.deepEqual(parseArgs(["--comments"], env), { agent: "from-env", comments: "env.toml" });
  // an unrelated argument followed by a value is not --comments
  assert.deepEqual(parseArgs(["--other", "x.toml"], {}), { agent: "", comments: undefined });
  // the value after --agent is taken as its value, not read as a flag of its own
  assert.deepEqual(parseArgs(["--agent", "--comments", "c.toml"], {}), { agent: "--comments", comments: undefined });
});
