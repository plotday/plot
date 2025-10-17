#!/usr/bin/env node
import { chmodSync, writeFileSync } from "fs";
import { dirname, join } from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

// Create bin/package.json to mark the directory as CommonJS
const binPackageJson = {
  type: "commonjs",
};
const binPackageJsonPath = join(__dirname, "bin", "package.json");
writeFileSync(binPackageJsonPath, JSON.stringify(binPackageJson, null, 2));

// Create bin/plot.cjs wrapper that executes bin/index.js
const wrapperContent = `#!/usr/bin/env node
// This is a wrapper that runs the compiled CLI
require('./index.js');
`;

const binPath = join(__dirname, "bin", "plot.cjs");
writeFileSync(binPath, wrapperContent);
chmodSync(binPath, 0o755);

console.log("✓ Built CLI");
