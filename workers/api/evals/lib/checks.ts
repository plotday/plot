import { spawnSync } from "node:child_process";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

import { TSC_BIN, TSCONFIG_BASE, TWISTER_DIST } from "./paths";
import { EvalInfraError } from "./types";
import type { CorpusSpec } from "./types";
import type { TwistSource } from "../../src/twist/types";

export interface CheckOutcome {
  status: "pass" | "assertion_failed" | "typecheck_failed";
  assertionFailures: string[];
  typecheckErrors: string[];
}

const DEFAULT_CLASS_RE = /export\s+default\s+class\s+\w+\s+extends\s+Twist\b/;

export function runUniversalChecks(source: TwistSource): string[] {
  const index = source.files["index.ts"];
  if (!index) return ["universal: files must include index.ts"];
  const failures: string[] = [];
  if (!DEFAULT_CLASS_RE.test(index)) {
    failures.push(
      "universal: index.ts must default-export a class extending Twist"
    );
  }
  return failures;
}

export function runAssertions(spec: CorpusSpec, source: TwistSource): string[] {
  const all = Object.values(source.files).join("\n\n");
  const failures: string[] = [];
  for (const a of spec.assertions) {
    if (!new RegExp(a.match).test(all)) {
      failures.push(`missing /${a.match}/ — ${a.why}`);
    }
  }
  for (const n of spec.notMatch) {
    if (new RegExp(n.pattern).test(all)) {
      failures.push(`forbidden /${n.pattern}/ — ${n.why}`);
    }
  }
  return failures;
}

/**
 * Type-check generated sources against the real @plotday/twister type
 * declarations (public/twister/dist), without installing twister. Extra
 * model-chosen deps are npm-installed into the temp dir first (they already
 * installed successfully inside the builder container, so a local failure is
 * an infra problem, not a generation failure).
 */
export async function typecheckSource(
  source: TwistSource
): Promise<{ ok: boolean; errors: string[] }> {
  const dir = await mkdtemp(join(tmpdir(), "twist-eval-tsc-"));
  try {
    const srcDir = join(dir, "src");
    await mkdir(srcDir, { recursive: true });
    for (const [name, content] of Object.entries(source.files)) {
      const filePath = join(srcDir, name);
      await mkdir(dirname(filePath), { recursive: true });
      await writeFile(filePath, content, "utf-8");
    }

    const extraDeps = Object.fromEntries(
      Object.entries(source.dependencies).filter(
        ([name]) => name !== "@plotday/twister"
      )
    );
    if (Object.keys(extraDeps).length > 0) {
      await writeFile(
        join(dir, "package.json"),
        JSON.stringify(
          { name: "twist-eval-typecheck", private: true, dependencies: extraDeps },
          null,
          2
        ),
        "utf-8"
      );
      const install = spawnSync(
        "npm",
        ["install", "--no-audit", "--no-fund", "--silent"],
        { cwd: dir, timeout: 120_000, encoding: "utf-8" }
      );
      if (install.error || install.signal || install.status !== 0) {
        throw new EvalInfraError(
          `npm install for typecheck failed:\n${
            install.stderr || install.stdout || install.signal || String(install.error ?? "unknown")
          }`
        );
      }
    }

    await writeFile(
      join(dir, "tsconfig.json"),
      JSON.stringify(
        {
          extends: TSCONFIG_BASE,
          compilerOptions: {
            noEmit: true,
            declaration: false,
            declarationMap: false,
            sourceMap: false,
            baseUrl: ".",
            types: [],
            paths: {
              "@plotday/twister": [join(TWISTER_DIST, "index.d.ts")],
              "@plotday/twister/*": [join(TWISTER_DIST, "*")],
            },
          },
          include: ["src/**/*.ts"],
        },
        null,
        2
      ),
      "utf-8"
    );

    const tsc = spawnSync(TSC_BIN, ["-p", dir], {
      timeout: 60_000,
      encoding: "utf-8",
    });
    if (tsc.error || tsc.signal) {
      throw new EvalInfraError(
        `tsc did not complete (${tsc.signal ?? (tsc.error as Error).message}) — ` +
          `check node_modules/.bin/tsc and system load`
      );
    }
    if (tsc.status === 0) return { ok: true, errors: [] };
    const errors = (tsc.stdout || tsc.stderr || "unknown tsc failure")
      .split("\n")
      .filter((line) => line.trim())
      .slice(0, 50);
    return { ok: false, errors };
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

export async function runChecks(
  spec: CorpusSpec,
  source: TwistSource
): Promise<CheckOutcome> {
  const assertionFailures = [
    ...runUniversalChecks(source),
    ...runAssertions(spec, source),
  ];
  if (assertionFailures.length > 0) {
    return { status: "assertion_failed", assertionFailures, typecheckErrors: [] };
  }
  const typecheck = await typecheckSource(source);
  if (!typecheck.ok) {
    return {
      status: "typecheck_failed",
      assertionFailures: [],
      typecheckErrors: typecheck.errors,
    };
  }
  return { status: "pass", assertionFailures: [], typecheckErrors: [] };
}
