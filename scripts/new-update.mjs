import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

export function slugify(text) {
  return text
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

export function randomId() {
  return Math.random().toString(36).slice(2, 8).padEnd(6, "0");
}

export function fragmentTemplate() {
  return "### Fixes\n\n- \n";
}

// CLI: node scripts/new-update.mjs "<description>" [dir=docs/updates.d]
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const desc = process.argv[2];
  const dir = process.argv[3] || "docs/updates.d";
  if (!desc) {
    console.error('usage: node scripts/new-update.mjs "<short description>"');
    process.exit(1);
  }
  const slug = slugify(desc) || "update";
  const path = join(dir, `${slug}-${randomId()}.md`);
  mkdirSync(dir, { recursive: true });
  writeFileSync(path, fragmentTemplate());
  console.log(`Created ${path} — edit it with your update bullet(s).`);
}
