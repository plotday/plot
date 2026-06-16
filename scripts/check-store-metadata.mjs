#!/usr/bin/env node
// Validates the app-store metadata files (the source of truth for shipped store
// copy) against each store's character limits. Apple App Store Connect and
// Google Play both reject metadata that exceeds these limits at upload time, so
// catching it in CI is cheaper than a failed `fastlane deliver`/`supply`.
//
// The copy itself lives in the fastlane metadata trees (one field per .txt
// file); docs/store-listings.md is guidance/rationale, not the source. See the
// "Where the copy lives" section of that doc.
//
// Microsoft Store (Windows) has no fastlane home and is submitted manually via
// Partner Center, so its copy stays in docs/store-listings.md and is NOT linted
// here.
//
// Run: node scripts/check-store-metadata.mjs   (or: pnpm lint:store-metadata)

import { readFileSync, existsSync, readdirSync } from "node:fs";
import { join, basename, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..");

// Per-field character limits, keyed by metadata filename.
// Apple: https://developer.apple.com/help/app-store-connect/reference/app-information
// Play:  https://support.google.com/googleplay/android-developer/answer/9859152
const LIMITS = {
  // Apple App Store (iOS + macOS)
  "name.txt": 30,
  "subtitle.txt": 30,
  "promotional_text.txt": 170,
  "keywords.txt": 100,
  "description.txt": 4000,
  "release_notes.txt": 4000,
  // Google Play
  "title.txt": 30,
  "short_description.txt": 80,
  "full_description.txt": 4000,
};

// Metadata roots to scan (each holds one .txt per field).
const ROOTS = [
  "apps/plot/ios/fastlane/metadata/en-US",
  "apps/plot/macos/fastlane/metadata/en-US",
  "apps/plot/android/fastlane/metadata/android/en-US",
];

// Count characters the way the stores do — by Unicode code point, not UTF-16
// units — and ignore a single trailing newline (editors add one; stores don't
// count it).
function charCount(text) {
  return [...text.replace(/\n$/, "")].length;
}

const violations = [];
let checked = 0;

for (const rootRel of ROOTS) {
  const root = join(repoRoot, rootRel);
  if (!existsSync(root)) continue;
  for (const entry of readdirSync(root)) {
    const limit = LIMITS[basename(entry)];
    if (limit === undefined) continue; // URLs, images, unknown fields — skip
    const file = join(root, entry);
    const count = charCount(readFileSync(file, "utf8"));
    checked++;
    if (count > limit) {
      violations.push({ file: join(rootRel, entry), count, limit });
    }
  }
}

if (violations.length > 0) {
  console.error("✗ Store metadata exceeds character limits:\n");
  for (const v of violations) {
    console.error(`  ${v.file}\n    ${v.count} chars > ${v.limit} limit (over by ${v.count - v.limit})`);
  }
  console.error(
    "\nTrim the offending file(s). These limits are enforced at upload by the stores.",
  );
  process.exit(1);
}

console.log(`✓ Store metadata within limits (${checked} fields checked across ${ROOTS.length} platforms).`);
