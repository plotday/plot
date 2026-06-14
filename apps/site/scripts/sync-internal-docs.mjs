import { mkdirSync, copyFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repoDocs = resolve(here, "../../../docs");
const outDir = resolve(here, "../app/lib/internal-docs");

mkdirSync(outDir, { recursive: true });
for (const file of ["features.md", "updates.md", "voice.md"]) {
  copyFileSync(resolve(repoDocs, file), resolve(outDir, file));
  console.log(`sync-internal-docs: copied ${file}`);
}
