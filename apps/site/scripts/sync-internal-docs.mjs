import { mkdirSync, copyFileSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { gatherFragments } from "../../../scripts/lib/updates-fragments.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repoDocs = resolve(here, "../../../docs");
const fragDir = resolve(here, "../../../docs/updates.d");
const outDir = resolve(here, "../app/lib/internal-docs");

mkdirSync(outDir, { recursive: true });
for (const file of ["features.md", "updates.md", "voice.md", "store-listings.md"]) {
  if (file === "updates.md") {
    const released = readFileSync(resolve(repoDocs, file), "utf8");
    const { body } = gatherFragments(fragDir);
    const combined = body ? `## Next release\n\n${body}\n\n${released}` : released;
    writeFileSync(resolve(outDir, file), combined);
    console.log(`sync-internal-docs: assembled ${file}${body ? " (with pending fragments)" : ""}`);
  } else {
    copyFileSync(resolve(repoDocs, file), resolve(outDir, file));
    console.log(`sync-internal-docs: copied ${file}`);
  }
}
