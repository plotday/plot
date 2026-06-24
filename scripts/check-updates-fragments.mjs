import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

export function validateFragment(content) {
  const errors = [];
  if (!/^### .+/m.test(content)) errors.push("missing a ### section heading");
  if (!/^- /m.test(content)) errors.push("missing a - bullet");
  if (/^## /m.test(content)) errors.push("contains a ## top-level heading (use ### sections only)");
  return errors;
}

// CLI: node scripts/check-updates-fragments.mjs [dir=docs/updates.d]
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const dir = process.argv[2] || "docs/updates.d";
  if (!existsSync(dir)) {
    console.log("check-updates-fragments: no docs/updates.d directory — nothing to check.");
    process.exit(0);
  }
  const names = readdirSync(dir).filter((n) => n.endsWith(".md") && n !== "README.md");
  let failed = false;
  for (const name of names) {
    const errors = validateFragment(readFileSync(join(dir, name), "utf8"));
    if (errors.length) {
      failed = true;
      console.error(`✗ ${name}:`);
      for (const e of errors) console.error(`    - ${e}`);
    }
  }
  if (failed) {
    console.error("check-updates-fragments: invalid fragment(s) found.");
    process.exit(1);
  }
  console.log(`check-updates-fragments: ${names.length} fragment(s) OK.`);
}
