import { test } from "node:test";
import assert from "node:assert/strict";

import { stampUpdates } from "./stamp-updates.mjs";

test("renames the `## Next release` heading, preserving grouped sections", () => {
  const input = [
    "## Next release",
    "",
    "### Focuses",
    "- suggested focuses",
    "",
    "### Fixes",
    "- fixed a flicker",
    "",
  ].join("\n");
  const { stamped, content } = stampUpdates(input, "1.4.0+354", "2026-06-10");
  assert.equal(stamped, true);
  assert.match(content, /^## 1\.4\.0\+354 — 2026-06-10\n/);
  // grouped sections and their bullets are preserved untouched
  assert.match(content, /### Focuses\n- suggested focuses/);
  assert.match(content, /### Fixes\n- fixed a flicker/);
  // no stray "Next release" heading remains
  assert.equal(content.includes("## Next release"), false);
});

test("renames `## Next release` even when an older stamped release sits below", () => {
  const input = [
    "## Next release",
    "",
    "### Notes",
    "- a fresh note feature",
    "",
    "## 1.4.0+353 — 2026-05-21",
    "",
    "### Fixes",
    "- shipped in 353",
    "",
  ].join("\n");
  const { stamped, content } = stampUpdates(input, "1.4.0+354", "2026-06-10");
  assert.equal(stamped, true);
  const idxNew = content.indexOf("## 1.4.0+354");
  const idxOld = content.indexOf("## 1.4.0+353");
  assert.ok(idxNew >= 0 && idxOld > idxNew, "new heading precedes the prior release");
  assert.match(content, /## 1\.4\.0\+354 — 2026-06-10\n\n### Notes\n- a fresh note feature/);
  // the older release is left untouched
  assert.match(content, /## 1\.4\.0\+353 — 2026-05-21\n\n### Fixes\n- shipped in 353/);
});

test("skips when `## Next release` has no bullets", () => {
  const input = [
    "## Next release",
    "",
    "## 1.4.0+353 — 2026-05-21",
    "",
    "- shipped in 353",
    "",
  ].join("\n");
  const { stamped, content } = stampUpdates(input, "1.4.0+354", "2026-06-10");
  assert.equal(stamped, false);
  assert.equal(content, input);
});

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
