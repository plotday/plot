import { test } from "node:test";
import assert from "node:assert/strict";

import { stampUpdates } from "./stamp-updates.mjs";

test("stamps unreleased bullets above the first legacy --- separator", () => {
  const input = ["- new thing one", "- new thing two", "", "---", "", "- old published thing", ""].join("\n");
  const { stamped, content } = stampUpdates(input, "1.1.0+296", "2026-06-10");
  assert.equal(stamped, true);
  assert.match(content, /^## 1\.1\.0\+296 — 2026-06-10\n\n- new thing one\n- new thing two/);
  // legacy history is preserved untouched, below the new section
  assert.match(content, /---\n\n- old published thing/);
});

test("inserts above a prior ## version heading, preserving it", () => {
  const input = ["- fresh bullet", "", "## 1.1.0+295 — 2026-06-03", "", "- shipped in 295", ""].join("\n");
  const { stamped, content } = stampUpdates(input, "1.1.0+296", "2026-06-10");
  assert.equal(stamped, true);
  const idx296 = content.indexOf("## 1.1.0+296");
  const idx295 = content.indexOf("## 1.1.0+295");
  assert.ok(idx296 >= 0 && idx295 > idx296, "new heading precedes the old one");
  assert.match(content, /## 1\.1\.0\+296 — 2026-06-10\n\n- fresh bullet/);
});

test("skips when the unreleased block has no bullets", () => {
  const input = ["## 1.1.0+295 — 2026-06-03", "", "- shipped in 295", ""].join("\n");
  const { stamped, content } = stampUpdates(input, "1.1.0+296", "2026-06-10");
  assert.equal(stamped, false);
  assert.equal(content, input);
});

test("stamps the whole file when there is no heading or separator", () => {
  const input = ["- only bullet", ""].join("\n");
  const { stamped, content } = stampUpdates(input, "1.1.0+296", "2026-06-10");
  assert.equal(stamped, true);
  assert.match(content, /^## 1\.1\.0\+296 — 2026-06-10\n\n- only bullet/);
});
