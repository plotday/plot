import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { parseFragment, assembleFragments, gatherFragments } from "./updates-fragments.mjs";

test("parseFragment splits sections and trims blank lines", () => {
  const blocks = parseFragment("### Fixes\n\n- one\n- two\n\n");
  assert.deepEqual(blocks, [{ heading: "Fixes", body: "- one\n- two" }]);
});

test("parseFragment keeps wrapped continuation lines verbatim", () => {
  const blocks = parseFragment("### Threads\n\n- a long bullet\n  wrapped here\n");
  assert.deepEqual(blocks, [{ heading: "Threads", body: "- a long bullet\n  wrapped here" }]);
});

test("parseFragment handles multiple sections in one fragment", () => {
  const blocks = parseFragment("### Threads\n\n- feature\n\n### Fixes\n\n- fix\n");
  assert.deepEqual(blocks, [
    { heading: "Threads", body: "- feature" },
    { heading: "Fixes", body: "- fix" },
  ]);
});

test("assembleFragments merges identical headings and forces Fixes last", () => {
  const out = assembleFragments([
    "### Fixes\n\n- fix one\n",
    "### Threads\n\n- thread feature\n",
    "### Fixes\n\n- fix two\n",
  ]);
  assert.equal(out, "### Threads\n\n- thread feature\n\n### Fixes\n\n- fix one\n- fix two");
});

test("assembleFragments returns empty string with no input", () => {
  assert.equal(assembleFragments([]), "");
});

test("gatherFragments reads sorted .md files, excludes README.md", () => {
  const dir = mkdtempSync(join(tmpdir(), "frag-"));
  writeFileSync(join(dir, "b-second.md"), "### Fixes\n\n- second\n");
  writeFileSync(join(dir, "a-first.md"), "### Threads\n\n- first\n");
  writeFileSync(join(dir, "README.md"), "# how to add an update\n");
  const { body, files } = gatherFragments(dir);
  assert.equal(body, "### Threads\n\n- first\n\n### Fixes\n\n- second");
  assert.equal(files.length, 2);
  assert.ok(files[0].endsWith("a-first.md") && files[1].endsWith("b-second.md"));
});

test("gatherFragments on a missing dir returns empty", () => {
  const { body, files } = gatherFragments(join(tmpdir(), "does-not-exist-xyz"));
  assert.equal(body, "");
  assert.deepEqual(files, []);
});
