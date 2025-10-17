import { execSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import * as out from "../utils/output";

interface LintOptions {
  dir: string;
}

export function lintCommand(options: LintOptions) {
  const agentPath = path.resolve(process.cwd(), options.dir);

  // Verify we're in an agent directory by checking for package.json
  const packageJsonPath = path.join(agentPath, "package.json");
  if (!fs.existsSync(packageJsonPath)) {
    out.error(
      "package.json not found. Are you in an agent directory?",
      "Run this command from your agent's root directory",
    );
    process.exit(1);
  }

  const tsconfigPath = path.join(agentPath, "tsconfig.json");
  if (!fs.existsSync(tsconfigPath)) {
    out.error("tsconfig.json not found");
    process.exit(1);
  }

  out.progress("Checking for errors...");

  try {
    execSync("tsc --noEmit", {
      cwd: agentPath,
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
