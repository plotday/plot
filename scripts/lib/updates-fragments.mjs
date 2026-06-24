import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";

/** Parse a fragment into `{ heading, body }` blocks. Lines before the first
 *  `### ` heading are ignored. Bullet text (including wrapped continuation
 *  lines) is preserved verbatim; only blank lines around a block are trimmed. */
export function parseFragment(content) {
  const lines = content.split("\n");
  const blocks = [];
  let current = null;
  for (const line of lines) {
    const m = /^### (.+)$/.exec(line);
    if (m) {
      current = { heading: m[1].trim(), lines: [] };
      blocks.push(current);
    } else if (current) {
      current.lines.push(line);
    }
  }
  return blocks.map(({ heading, lines }) => {
    let start = 0;
    let end = lines.length;
    while (start < end && lines[start].trim() === "") start++;
    while (end > start && lines[end - 1].trim() === "") end--;
    return { heading, body: lines.slice(start, end).join("\n") };
  });
}

/** Merge fragment contents into grouped sections. Headings appear in first-seen
 *  order, except a `Fixes` section is forced last. Returns the section body
 *  WITHOUT a top-level `##` heading. */
export function assembleFragments(contents) {
  const order = [];
  const byHeading = new Map();
  for (const content of contents) {
    for (const { heading, body } of parseFragment(content)) {
      if (!byHeading.has(heading)) {
        byHeading.set(heading, []);
        order.push(heading);
      }
      byHeading.get(heading).push(body);
    }
  }
  const ordered = [
    ...order.filter((h) => h !== "Fixes"),
    ...order.filter((h) => h === "Fixes"),
  ];
  return ordered
    .map((h) => `### ${h}\n\n${byHeading.get(h).join("\n")}`)
    .join("\n\n");
}

/** Read all fragment `.md` files in `dir` (excluding README.md), filename-sorted,
 *  and assemble them. Returns the grouped body and the absolute file paths. */
export function gatherFragments(dir) {
  const abs = resolve(dir);
  if (!existsSync(abs)) return { body: "", files: [] };
  const names = readdirSync(abs)
    .filter((n) => n.endsWith(".md") && n !== "README.md")
    .sort();
  const files = names.map((n) => join(abs, n));
  const body = assembleFragments(files.map((f) => readFileSync(f, "utf8")));
  return { body, files };
}
