import { test } from "node:test";
import assert from "node:assert/strict";

import { stampUpdates, extractNextRelease } from "./stamp-updates.mjs";

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

test("prepends a stamped block built from fragment body, keeping prior releases", () => {
  const released = "## 1.4.0+353 — 2026-05-21\n\n### Fixes\n- shipped in 353\n";
  const fragmentBody = "### Threads\n\n- a new thread feature\n\n### Fixes\n\n- a new fix";
  const { stamped, content } = stampUpdates(released, "1.5.0+360", "2026-06-23", fragmentBody);
  assert.equal(stamped, true);
  assert.match(content, /^## 1\.5\.0\+360 — 2026-06-23\n\n### Threads\n\n- a new thread feature\n\n### Fixes\n\n- a new fix/);
  const idxNew = content.indexOf("## 1.5.0+360");
  const idxOld = content.indexOf("## 1.4.0+353");
  assert.ok(idxNew >= 0 && idxOld > idxNew, "new release precedes the prior one");
});

test("no-op when there is neither a fragment body nor a legacy unreleased block", () => {
  const released = "## 1.4.0+353 — 2026-05-21\n\n### Fixes\n- shipped in 353\n";
  const { stamped, content } = stampUpdates(released, "1.5.0+360", "2026-06-23", "");
  assert.equal(stamped, false);
  assert.equal(content, released);
});

test("extractNextRelease pulls the block body and removes it from content", () => {
  const input = [
    "## Next release",
    "",
    "### Fixes",
    "- legacy fix",
    "",
    "## 1.0.0+1 — 2026-01-01",
    "",
    "- shipped",
    "",
  ].join("\n");
  const { nextBody, rest } = extractNextRelease(input);
  assert.equal(nextBody, "### Fixes\n- legacy fix");
  assert.equal(rest.includes("## Next release"), false);
  assert.match(rest, /^## 1\.0\.0\+1 — 2026-01-01/);
});

test("extractNextRelease with no block returns content unchanged", () => {
  const input = "## 1.0.0+1 — 2026-01-01\n\n- shipped\n";
  const { nextBody, rest } = extractNextRelease(input);
  assert.equal(nextBody, "");
  assert.equal(rest, input);
});

test("fragment stamp folds a legacy ## Next release block in, Fixes last", () => {
  const content = [
    "## Next release",
    "",
    "### Connections",
    "- a connection note",
    "",
    "### Fixes",
    "- a legacy fix",
    "",
    "## 1.5.0+366 — 2026-06-24",
    "",
    "### Fixes",
    "- shipped in 366",
    "",
  ].join("\n");
  const fragmentBody = "### Fixes\n\n- a fragment fix";
  const { stamped, content: out } = stampUpdates(content, "1.6.0+370", "2026-07-01", fragmentBody);
  assert.equal(stamped, true);
  assert.equal(out.includes("## Next release"), false);
  assert.match(
    out,
    /^## 1\.6\.0\+370 — 2026-07-01\n\n### Connections\n\n- a connection note\n\n### Fixes\n\n- a legacy fix\n- a fragment fix/,
  );
  assert.match(out, /## 1\.5\.0\+366 — 2026-06-24\n\n### Fixes\n- shipped in 366/);
});
