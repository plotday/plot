import { execSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import * as out from "../utils/output";

interface LintOptions {
  dir: string;
}

export function lintCommand(options: LintOptions) {
  const twistPath = path.resolve(process.cwd(), options.dir);

  // Verify we're in an twist directory by checking for package.json
  const packageJsonPath = path.join(twistPath, "package.json");
  if (!fs.existsSync(packageJsonPath)) {
    out.error(
      "package.json not found. Are you in an twist directory?",
      "Run this command from your twist's root directory",
    );
    process.exit(1);
  }

  const tsconfigPath = path.join(twistPath, "tsconfig.json");
  if (!fs.existsSync(tsconfigPath)) {
    out.error("tsconfig.json not found");
    process.exit(1);
  }

  out.progress("Checking for errors...");

  try {
    execSync("tsc --noEmit", {
      cwd: twistPath,
      stdio: "inherit",
    });
    out.success("All good! No errors found");
    out.blank();
  } catch (error) {
    out.error("Found TypeScript errors");
    out.blank();
    process.exit(1);
  }
}
