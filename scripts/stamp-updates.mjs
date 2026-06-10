import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

/**
 * Insert a `## <version> — <date>` heading above the unreleased bullets at the
 * top of an updates.md changelog. The unreleased block is everything above the
 * first `## ` version heading, or (if none) above the first `---` separator, or
 * (if neither) the whole file. Returns `{ stamped, content }`; `stamped` is
 * false (and content unchanged) when the unreleased block has no `- ` bullet.
 */
export function stampUpdates(content, version, date) {
  const lines = content.split("\n");

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

  const heading = `## ${version} — ${date}`;
  let out = `${heading}\n\n${unreleased}`;
  if (rest.trim().length > 0) {
    out += `\n\n${rest}`;
  }
  if (content.endsWith("\n")) {
    out += "\n";
  }
  return { stamped: true, content: out };
}

// CLI: node scripts/stamp-updates.mjs <version> <date> [path=docs/updates.md]
if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [version, date, file = "docs/updates.md"] = process.argv.slice(2);
  if (!version || !date) {
    console.error("usage: node scripts/stamp-updates.mjs <version> <date> [path]");
    process.exit(1);
  }
  const original = readFileSync(file, "utf8");
  const { stamped, content } = stampUpdates(original, version, date);
  if (!stamped) {
    console.log(`stamp-updates: no unreleased bullets — skipping ${version}`);
    process.exit(0);
  }
  writeFileSync(file, content);
  console.log(`stamp-updates: stamped ${file} for ${version} (${date})`);
}
