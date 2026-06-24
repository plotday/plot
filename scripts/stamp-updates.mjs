import { readFileSync, writeFileSync, unlinkSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { gatherFragments, assembleFragments } from "./lib/updates-fragments.mjs";

/** Split out a legacy `## Next release` block (from before the fragment
 *  workflow). Returns the block's `### ` section body (without the `##` line)
 *  and the content with that block removed. No block → { nextBody: "", rest }. */
export function extractNextRelease(content) {
  const lines = content.split("\n");
  const idx = lines.findIndex((l) => l.trim() === "## Next release");
  if (idx === -1) return { nextBody: "", rest: content };
  let end = lines.length;
  for (let i = idx + 1; i < lines.length; i++) {
    if (lines[i].startsWith("## ")) {
      end = i;
      break;
    }
  }
  const nextBody = lines.slice(idx + 1, end).join("\n").trim();
  const rest = [...lines.slice(0, idx), ...lines.slice(end)].join("\n");
  return { nextBody, rest };
}

/**
 * Stamp an updates.md changelog for a release.
 *
 * Current convention: the in-progress changelog lives under a `## Next release`
 * heading, with its bullets grouped into `### <feature>` sections (and a final
 * `### Fixes`). Stamping renames that heading in place to `## <version> —
 * <date>`, preserving every grouped section beneath it. The next changelog
 * entry recreates a fresh `## Next release` section at the top (see AGENTS.md),
 * so we don't pre-insert an empty one here.
 *
 * Legacy fallback (no `## Next release` heading): insert a `## <version> —
 * <date>` heading above the unreleased bullets — everything above the first
 * `## ` version heading, or (if none) the first `---` separator, or the whole
 * file. Retained so older changelog shapes still stamp correctly.
 *
 * Returns `{ stamped, content }`; `stamped` is false (and content unchanged)
 * when the current-release block has no `- ` bullet to ship.
 */
export function stampUpdates(content, version, date, fragmentBody = "") {
  const lines = content.split("\n");
  const heading = `## ${version} — ${date}`;

  // Preferred path: assemble pending fragments into a fresh stamped block.
  if (fragmentBody.trim()) {
    // Fold any legacy `## Next release` block (from a pre-fragment PR) into the
    // same stamped version block so it can't be stranded mid-history.
    const { nextBody, rest: withoutNext } = extractNextRelease(content);
    const body = nextBody
      ? assembleFragments([nextBody, fragmentBody])
      : fragmentBody.trim();
    const rest = withoutNext.replace(/^\n+/, "");
    let out = `${heading}\n\n${body}`;
    if (rest.trim().length > 0) out += `\n\n${rest}`;
    if (content.endsWith("\n") && !out.endsWith("\n")) out += "\n";
    return { stamped: true, content: out };
  }

  // Legacy path: a literal `## Next release` heading marks the cycle.
  const nextIdx = lines.findIndex((l) => l.trim() === "## Next release");
  if (nextIdx !== -1) {
    let end = lines.length;
    for (let i = nextIdx + 1; i < lines.length; i++) {
      if (lines[i].startsWith("## ")) {
        end = i;
        break;
      }
    }
    const section = lines.slice(nextIdx + 1, end).join("\n");
    if (!/^- /m.test(section)) {
      return { stamped: false, content };
    }
    lines[nextIdx] = heading;
    return { stamped: true, content: lines.join("\n") };
  }

  // Legacy fallback.
  let boundary = lines.length;
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].startsWith("## ")) {
      boundary = i;
      break;
    }
    if (lines[i].trim() === "---" && boundary === lines.length) {
      boundary = i;
    }
  }

  const unreleased = lines.slice(0, boundary).join("\n").trim();
  const rest = lines.slice(boundary).join("\n").replace(/^\n+/, "");

  if (!/^- /m.test(unreleased)) {
    return { stamped: false, content };
  }

  let out = `${heading}\n\n${unreleased}`;
  if (rest.trim().length > 0) {
    out += `\n\n${rest}`;
  }
  if (content.endsWith("\n")) {
    out += "\n";
  }
  return { stamped: true, content: out };
}

// CLI: node scripts/stamp-updates.mjs <version> <date> [path=docs/updates.md] [fragdir=docs/updates.d]
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [version, date, file = "docs/updates.md", fragDir = "docs/updates.d"] = process.argv.slice(2);
  if (!version || !date) {
    console.error("usage: node scripts/stamp-updates.mjs <version> <date> [path] [fragdir]");
    process.exit(1);
  }
  const { body, files } = gatherFragments(fragDir);
  const original = readFileSync(file, "utf8");
  const { stamped, content } = stampUpdates(original, version, date, body);
  if (!stamped) {
    console.log(`stamp-updates: no pending fragments or bullets — skipping ${version}`);
    process.exit(0);
  }
  writeFileSync(file, content);
  for (const f of files) unlinkSync(f);
  console.log(`stamp-updates: stamped ${file} for ${version} (${date}); removed ${files.length} fragment(s)`);
}
