import { pathToFileURL } from "node:url";

import { gatherFragments } from "./lib/updates-fragments.mjs";

// CLI: node scripts/preview-updates.mjs [dir=docs/updates.d]
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const dir = process.argv[2] || "docs/updates.d";
  const { body } = gatherFragments(dir);
  if (!body) {
    console.log("No updates queued for the next release.");
  } else {
    console.log(`## Next release\n\n${body}`);
  }
}
