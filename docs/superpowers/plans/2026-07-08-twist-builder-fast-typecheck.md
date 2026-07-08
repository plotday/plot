# Twist Builder Fast Templates + In-Loop Typecheck Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove `npm install` from the twist-build hot path via version-keyed dependency templates, and fail builds on TypeScript errors (tsc + esbuild in parallel, merged errors) so the retry loop can repair type-broken generations.

**Architecture:** A new `templates.ts` module in the container server manages `/templates/<version>/` dirs (package.json + node_modules + tsconfig, populated once per twister version behind a shared in-flight promise, LRU-pruned). The `/build` endpoint hardlink-copies the template, installs only model-requested extra deps, then runs `tsc --noEmit` and `plot build` concurrently, merging failures with a stable `Type check failed:` marker. The API sends its bundled `@plotday/twister` version with each build; the harness classifier gains a `build_typecheck` class.

**Tech Stack:** Node 22 container (express, npm, global typescript + @plotday/twister CLI), vitest (new, in the server package), Cloudflare Containers, eval harness.

**Spec:** `docs/superpowers/specs/2026-07-08-twist-builder-fast-typecheck-design.md` — read before starting.

**Spec amendment (decided at plan time):** if populating the template for the requested exact version fails (e.g. the workspace twister version isn't published to npm yet — common in dev), the server logs a warning and falls back to the resolved-`latest` template; only when that also fails does the build return the install-failure error. Prod versions are always published, so prod behavior matches the spec.

## Global Constraints

- Branch: `twist-builder-fast-typecheck` (off main). Work in the worktree `/Users/kris.braun/code/plot/.claude/worktrees/twist-gen-eval-harness`.
- `BuildResult` wire contract stays backward compatible: success variant may gain OPTIONAL `templateCache?: "hit" | "miss"`; failure variant unchanged (`{success:false, errors: string[]}`).
- Marker strings are load-bearing: tsc failures MUST be prefixed `Type check failed:` and dependency-install failures MUST keep the existing `Failed to install dependencies:` prefix (the harness classifier keys on both).
- A build succeeds ONLY if both tsc and esbuild pass; when both fail, BOTH error sets are returned.
- `twisterVersion` absent from the request → resolve `latest` once per boot and use that (backward compatible).
- No generator/retry/prompt changes; no container sharding; the harness's own level-4 typecheck stays untouched.
- Lint gates: workers/api `pnpm --filter @plotday/api lint` → 0 errors, no new warnings; container server `npm run build` (tsc) clean.
- Every commit message ends with: `Co-Authored-By: Claude <noreply@anthropic.com>`

---

### Task 1: Template manager module (container server) + unit tests

**Files:**
- Create: `workers/api/containers/twist-builder/server/src/templates.ts`
- Create: `workers/api/containers/twist-builder/server/src/templates.test.ts`
- Modify: `workers/api/containers/twist-builder/server/package.json` (vitest devDep + test script)

**Interfaces:**
- Consumes: nothing project-internal (pure node fs/child_process).
- Produces (Task 2 imports): `getTemplate(version: string, installer?: Installer, templatesDir?: string): Promise<TemplateResult>` where `TemplateResult = { dir: string; cache: "hit" | "miss" }`; `type Installer = (dir: string) => Promise<void>`; `pruneTemplates(templatesDir?: string, keep?: number): Promise<void>`; `TEMPLATES_DIR` const.

- [ ] **Step 1: Add vitest to the server package**

In `workers/api/containers/twist-builder/server/package.json` add `"test": "vitest run"` to scripts and `"vitest": "^3.0.5"` to devDependencies, then run `npm install` in that directory (commit the resulting package-lock.json).

- [ ] **Step 2: Write the failing tests**

`workers/api/containers/twist-builder/server/src/templates.test.ts`:

```ts
import { mkdtemp, readFile, readdir, mkdir, writeFile, utimes } from "fs/promises";
import { tmpdir } from "os";
import { join } from "path";
import { describe, it, expect } from "vitest";

import { getTemplate, pruneTemplates, type Installer } from "./templates.js";

async function freshDir(): Promise<string> {
  return mkdtemp(join(tmpdir(), "tpl-test-"));
}

// Fake installer: writes the sentinel file getTemplate uses to detect a
// populated template, so no real npm runs in unit tests.
function fakeInstaller(calls: string[]): Installer {
  return async (dir) => {
    calls.push(dir);
    const pkgDir = join(dir, "node_modules", "@plotday", "twister");
    await mkdir(pkgDir, { recursive: true });
    await writeFile(join(pkgDir, "package.json"), "{}", "utf-8");
  };
}

describe("getTemplate", () => {
  it("populates on first call and reuses on the second", async () => {
    const dir = await freshDir();
    const calls: string[] = [];
    const first = await getTemplate("1.2.3", fakeInstaller(calls), dir);
    expect(first.cache).toBe("miss");
    const second = await getTemplate("1.2.3", fakeInstaller(calls), dir);
    expect(second.cache).toBe("hit");
    expect(second.dir).toBe(first.dir);
    expect(calls).toHaveLength(1);
    const pkg = JSON.parse(await readFile(join(first.dir, "package.json"), "utf-8"));
    expect(pkg.dependencies["@plotday/twister"]).toBe("1.2.3");
    const tsconfig = JSON.parse(await readFile(join(first.dir, "tsconfig.json"), "utf-8"));
    expect(tsconfig.compilerOptions.noEmit).toBe(true);
  });

  it("shares one populate across concurrent calls", async () => {
    const dir = await freshDir();
    const calls: string[] = [];
    const installer = fakeInstaller(calls);
    const [a, b, c] = await Promise.all([
      getTemplate("2.0.0", installer, dir),
      getTemplate("2.0.0", installer, dir),
      getTemplate("2.0.0", installer, dir),
    ]);
    expect(calls).toHaveLength(1);
    expect(a.dir).toBe(b.dir);
    expect(b.dir).toBe(c.dir);
  });

  it("rejects invalid version strings", async () => {
    const dir = await freshDir();
    await expect(
      getTemplate("1.0.0; rm -rf /", fakeInstaller([]), dir)
    ).rejects.toThrow(/Invalid twister version/);
  });

  it("cleans up after a failed install and retries fresh", async () => {
    const dir = await freshDir();
    const failing: Installer = async () => {
      throw new Error("registry down");
    };
    await expect(getTemplate("3.0.0", failing, dir)).rejects.toThrow(/registry down/);
    const calls: string[] = [];
    const ok = await getTemplate("3.0.0", fakeInstaller(calls), dir);
    expect(ok.cache).toBe("miss");
    expect(calls).toHaveLength(1);
  });
});

describe("pruneTemplates", () => {
  it("keeps only the N most recently used versions", async () => {
    const dir = await freshDir();
    const calls: string[] = [];
    for (const v of ["1.0.0", "1.0.1", "1.0.2", "1.0.3", "1.0.4"]) {
      await getTemplate(v, fakeInstaller(calls), dir);
      // Space out mtimes so LRU order is deterministic.
      const when = new Date(Date.now() - (5 - calls.length) * 60_000);
      await utimes(join(dir, v), when, when);
    }
    await pruneTemplates(dir, 2);
    const remaining = (await readdir(dir)).sort();
    expect(remaining).toHaveLength(2);
    expect(remaining).toContain("1.0.4");
  });
});
```

- [ ] **Step 3: Run to verify failure**

Run from `workers/api/containers/twist-builder/server`: `npm test`
Expected: FAIL — cannot find module `./templates.js`.

- [ ] **Step 4: Implement templates.ts**

```ts
import { exec } from "child_process";
import { mkdir, readdir, rm, stat, utimes, writeFile } from "fs/promises";
import { join } from "path";
import { promisify } from "util";

const execAsync = promisify(exec);

export const TEMPLATES_DIR = process.env.TEMPLATES_DIR ?? "/templates";
const MAX_TEMPLATES = 4;

export type Installer = (dir: string) => Promise<void>;

export interface TemplateResult {
  dir: string;
  cache: "hit" | "miss";
}

const defaultInstaller: Installer = async (dir) => {
  await execAsync(`cd ${dir} && npm install --no-audit --no-fund`, {
    timeout: 180_000,
  });
};

// One in-flight populate per version — concurrent builds for the same
// version await a single install instead of racing npm.
const inflight = new Map<string, Promise<TemplateResult>>();

export async function getTemplate(
  version: string,
  installer: Installer = defaultInstaller,
  templatesDir: string = TEMPLATES_DIR
): Promise<TemplateResult> {
  if (!/^[0-9A-Za-z.\-]+$/.test(version)) {
    throw new Error(`Invalid twister version: ${version}`);
  }
  const dir = join(templatesDir, version);
  try {
    // Sentinel: a populated template has twister installed.
    await stat(join(dir, "node_modules", "@plotday", "twister", "package.json"));
    const now = new Date();
    await utimes(dir, now, now); // LRU touch
    return { dir, cache: "hit" };
  } catch {
    // fall through to populate
  }
  const existing = inflight.get(version);
  if (existing) return existing;
  const populate = (async (): Promise<TemplateResult> => {
    try {
      await rm(dir, { recursive: true, force: true }); // clear partial state
      await mkdir(dir, { recursive: true });
      await writeFile(
        join(dir, "package.json"),
        JSON.stringify(
          {
            name: `twist-template-${version}`,
            private: true,
            type: "module",
            dependencies: { "@plotday/twister": version },
          },
          null,
          2
        ),
        "utf-8"
      );
      await writeFile(
        join(dir, "tsconfig.json"),
        JSON.stringify(
          {
            extends: "@plotday/twister/tsconfig.base.json",
            compilerOptions: {
              noEmit: true,
              declaration: false,
              declarationMap: false,
              sourceMap: false,
            },
            include: ["src/**/*.ts"],
          },
          null,
          2
        ),
        "utf-8"
      );
      await installer(dir);
      await pruneTemplates(templatesDir, MAX_TEMPLATES);
      return { dir, cache: "miss" };
    } catch (error) {
      await rm(dir, { recursive: true, force: true });
      throw error;
    } finally {
      inflight.delete(version);
    }
  })();
  inflight.set(version, populate);
  return populate;
}

export async function pruneTemplates(
  templatesDir: string = TEMPLATES_DIR,
  keep: number = MAX_TEMPLATES
): Promise<void> {
  let entries: string[];
  try {
    entries = await readdir(templatesDir);
  } catch {
    return;
  }
  const stats = await Promise.all(
    entries.map(async (name) => {
      try {
        const s = await stat(join(templatesDir, name));
        return { name, mtime: s.mtimeMs, isDir: s.isDirectory() };
      } catch {
        return null;
      }
    })
  );
  const dirs = stats
    .filter((s): s is NonNullable<typeof s> => !!s && s.isDir)
    .sort((a, b) => b.mtime - a.mtime);
  for (const old of dirs.slice(keep)) {
    await rm(join(templatesDir, old.name), { recursive: true, force: true });
  }
}
```

Note the ESM import extension: the server package is `"type": "module"` compiled by plain tsc, so imports between local files use the `.js` extension (`./templates.js`) — if the server's tsconfig rejects that form, match whatever module/moduleResolution it uses and note the adjustment in your report.

- [ ] **Step 5: Run tests to verify pass**

Run: `npm test` (from the server dir). Expected: all 6 pass. Also `npm run build` — tsc compiles cleanly.

- [ ] **Step 6: Commit**

```bash
git add workers/api/containers/twist-builder/server
git commit -m "feat(api): version-keyed template manager for twist-builder container

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: Server build flow — template copy, extras-only install, parallel tsc + esbuild

**Files:**
- Modify: `workers/api/containers/twist-builder/server/src/server.ts`
- Modify: `workers/api/containers/twist-builder/Dockerfile`

**Interfaces:**
- Consumes: `getTemplate`, `TemplateResult` from `./templates.js` (Task 1).
- Produces: `/build` accepts optional `twisterVersion` in the JSON body; success responses gain `templateCache: "hit" | "miss"`; tsc failures prefixed `Type check failed:`; install failures keep `Failed to install dependencies:`; esbuild failures keep `Build failed:`.

- [ ] **Step 1: Rewrite the /build handler**

In `server.ts`: extend the request type and replace the setup+install+build section (everything between creating `buildDir` and reading the bundled module) with the following. Keep the surrounding validation, logging style, response reading of `build/index.js(.map)`, the module-size check, the outer try/catch, and the `finally` cleanup exactly as they are.

At the top, add the import and the latest-version resolver:

```ts
import { getTemplate, type TemplateResult } from "./templates.js";

// Resolved once per boot; used when the API doesn't pin a version
// (backward compatibility) and as the fallback when a pinned version
// can't be installed (e.g. unpublished workspace versions in dev).
let latestVersion: Promise<string> | null = null;
function resolveLatestVersion(): Promise<string> {
  latestVersion ??= execAsync("npm view @plotday/twister version", {
    timeout: 30_000,
  }).then((r) => r.stdout.trim());
  return latestVersion;
}
```

Request parsing (replacing `const source = req.body as TwistSource;`):

```ts
const { twisterVersion, ...sourceBody } = req.body as TwistSource & {
  twisterVersion?: string;
};
const source = sourceBody as TwistSource;
```

Template acquisition + build-dir setup (replacing the package.json write, source write stays, and the npm-install block):

```ts
// Acquire the dependency template for the requested twister version.
const requestedVersion = twisterVersion ?? (await resolveLatestVersion());
let template: TemplateResult;
try {
  template = await getTemplate(requestedVersion);
} catch (error: any) {
  if (twisterVersion) {
    // Pinned version unavailable (e.g. unpublished workspace version in
    // dev) — fall back to latest rather than failing the build.
    console.warn(
      `[${twistName}] template for ${requestedVersion} failed (${error?.message}); falling back to latest`
    );
    try {
      template = await getTemplate(await resolveLatestVersion());
    } catch (fallbackError: any) {
      return res.json({
        success: false,
        errors: [
          `Failed to install dependencies:\n${fallbackError?.message ?? String(fallbackError)}`,
        ],
      });
    }
  } else {
    return res.json({
      success: false,
      errors: [
        `Failed to install dependencies:\n${error?.message ?? String(error)}`,
      ],
    });
  }
}

// Hardlink-copy the template's node_modules (fast); fall back to a real
// copy if the filesystem refuses cross-links.
console.log(`[${twistName}] Copying template (${template.cache})...`);
try {
  await execAsync(`cp -al ${template.dir}/node_modules ${buildDir}/node_modules`);
} catch {
  await execAsync(`cp -R ${template.dir}/node_modules ${buildDir}/node_modules`);
}
await execAsync(`cp ${template.dir}/tsconfig.json ${buildDir}/tsconfig.json`);

// package.json: template deps plus any extra deps the model requested.
const extraDeps = Object.fromEntries(
  Object.entries(source.dependencies).filter(([name]) => name !== "@plotday/twister")
);
await writeFile(
  join(buildDir, "package.json"),
  JSON.stringify(
    {
      name: twistName,
      version: "1.0.0",
      type: "module",
      main: "src/index.ts",
      dependencies: { "@plotday/twister": requestedVersion, ...extraDeps },
    },
    null,
    2
  ),
  "utf-8"
);

// (existing source-file writing loop stays here unchanged)

// Install ONLY when the model requested extra dependencies.
if (Object.keys(extraDeps).length > 0) {
  console.log(`[${twistName}] Installing extra dependencies: ${Object.keys(extraDeps).join(", ")}...`);
  try {
    await execAsync(`cd ${buildDir} && npm install --no-audit --no-fund`, {
      timeout: 180_000,
    });
  } catch (error: any) {
    return res.json({
      success: false,
      errors: [
        `Failed to install dependencies:\n${error.stderr || error.stdout || error.message}`,
      ],
    });
  }
}
```

Build step (replacing the single `plot build` exec):

```ts
// Type-check and bundle in parallel: a build succeeds only if both pass,
// and failures return BOTH error sets so one retry can fix everything.
console.log(`[${twistName}] Type-checking and bundling...`);
const firstLines = (text: string, n: number) =>
  text.split("\n").slice(0, n).join("\n");
const [tscError, bundleError] = await Promise.all([
  execAsync(`cd ${buildDir} && tsc -p .`, { timeout: 60_000 }).then(
    () => null,
    (e: any) => e
  ),
  execAsync(`cd ${buildDir} && plot build`, { timeout: 60_000 }).then(
    () => null,
    (e: any) => e
  ),
]);
if (tscError || bundleError) {
  const errors: string[] = [];
  if (tscError) {
    errors.push(
      `Type check failed:\n${firstLines(
        tscError.stdout || tscError.stderr || tscError.message,
        80
      )}`
    );
  }
  if (bundleError) {
    errors.push(
      `Build failed:\n${bundleError.stderr || bundleError.stdout || bundleError.message}`
    );
  }
  return res.json({ success: false, errors });
}
```

Success response: add the cache field —

```ts
res.json({
  success: true,
  module: moduleCode,
  sourcemap: sourcemapCode,
  templateCache: template.cache,
} as BuildResult);
```

and extend the local `BuildResult` type's success variant with `templateCache?: "hit" | "miss"`.

- [ ] **Step 2: Dockerfile**

In `workers/api/containers/twist-builder/Dockerfile`, after the global twister install add:

```dockerfile
# tsc for in-loop typechecking; pinned to match the server's devDependency major
RUN npm install -g typescript@5.8.3

# Version-keyed dependency templates (populated at runtime)
RUN mkdir -p /templates
```

- [ ] **Step 3: Compile check**

Run from the server dir: `npm run build` — clean; `npm test` — the Task 1 suite still passes.

- [ ] **Step 4: Commit**

```bash
git add workers/api/containers/twist-builder
git commit -m "feat(api): twist builds use dependency templates + parallel tsc/esbuild

npm install leaves the hot path (template hardlink copy instead; extras
only when the model requests them), and type errors now fail the build
with a stable 'Type check failed:' marker so the generator's retry loop
can repair them.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: API sends its bundled twister version

**Files:**
- Modify: `workers/api/src/twist/builder.ts`
- Modify: `workers/api/src/twist/types.ts` (additive field)

**Interfaces:**
- Consumes: the workspace-linked `@plotday/twister` package.json (via relative path — its exports map has no `./package.json` entry, so the bare-specifier form won't resolve).
- Produces: `/build` POST bodies carry `twisterVersion` equal to the version of the twister the API bundles (the same package `getBuilderDocumentation()` reads).

- [ ] **Step 1: Implement**

In `workers/api/src/twist/builder.ts`, add at the top (worker tsconfig has `resolveJsonModule: true`):

```ts
// The twister exports map has no ./package.json entry, so import it by
// path. This is the SAME package the prompt docs come from — sending its
// version pins container builds to the docs the model saw.
import twisterPackage from "../../node_modules/@plotday/twister/package.json";
```

and change the fetch body to:

```ts
      body: JSON.stringify({ ...source, twisterVersion: twisterPackage.version }),
```

If eslint flags the node_modules path import, add a one-line `// eslint-disable-next-line` with the rule name above the import.

In `workers/api/src/twist/types.ts`, extend the `BuildResult` success variant with `templateCache?: "hit" | "miss"` (additive; nothing consumes it in the worker — it exists for e2e/eval observability).

- [ ] **Step 2: Verify**

Run from workers/api: `npx vitest run src/twist/generator.test.ts` (builder is mocked there — must still pass), then `pnpm --filter @plotday/api lint` — 0 errors, no new warnings.

- [ ] **Step 3: Commit**

```bash
git add workers/api/src/twist/builder.ts workers/api/src/twist/types.ts
git commit -m "feat(api): pin container builds to the API's bundled twister version

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: Harness classifier — build_typecheck

**Files:**
- Modify: `workers/api/evals/lib/types.ts`
- Modify: `workers/api/evals/lib/classify.ts`
- Test: `workers/api/evals/__tests__/classify.test.ts`

**Interfaces:**
- Consumes: existing `BuildFailureClass`, `classifyBuildErrors`.
- Produces: `BuildFailureClass` union gains `"build_typecheck"`; `FailureClass` union gains it too (via BuildFailureClass usage sites — check both unions).

- [ ] **Step 1: Write failing tests**

Add to the `classifyBuildErrors` describe in `workers/api/evals/__tests__/classify.test.ts`:

```ts
  it("detects typecheck failures", () => {
    expect(
      classifyBuildErrors(["Type check failed:\nsrc/index.ts(3,7): error TS2322: ..."])
    ).toBe("build_typecheck");
  });

  it("prefers typecheck over bundle when both are present", () => {
    expect(
      classifyBuildErrors([
        "Type check failed:\nsrc/index.ts(3,7): error TS2322: ...",
        "Build failed:\nesbuild: Expected ';'",
      ])
    ).toBe("build_typecheck");
  });

  it("still prefers npm-install failures over typecheck", () => {
    expect(
      classifyBuildErrors([
        "Failed to install dependencies:\nnpm ERR! 404",
        "Type check failed:\nerror TS2304",
      ])
    ).toBe("build_npm_install");
  });
```

- [ ] **Step 2: Run to verify failure**

Run from workers/api: `npx vitest run evals/__tests__/classify.test.ts` — the three new tests FAIL (returns `build_bundle`).

- [ ] **Step 3: Implement**

In `workers/api/evals/lib/types.ts`, extend the unions:

```ts
export type FailureClass =
  | "api_error"
  | "output_truncated"
  | "schema_mismatch"
  | "build_npm_install"
  | "build_typecheck"
  | "build_bundle"
  | "build_container_infra"
  | "max_attempts_exhausted"
  | "assertion_failed"
  | "typecheck_failed"
  | "timeout"
  | "infra";

export type BuildFailureClass =
  | "build_npm_install"
  | "build_typecheck"
  | "build_bundle"
  | "build_container_infra";
```

In `workers/api/evals/lib/classify.ts`, insert the typecheck branch AFTER the npm-install and container-infra checks and BEFORE the `build_bundle` default:

```ts
  if (joined.includes("Type check failed")) {
    return "build_typecheck";
  }
```

- [ ] **Step 4: Verify**

Run: `npx vitest run evals/` — all pass (13 classify tests now). `pnpm --filter @plotday/api lint` — clean.

- [ ] **Step 5: Commit**

```bash
git add workers/api/evals
git commit -m "feat(api): eval taxonomy distinguishes in-loop typecheck failures

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: E2E extension + measured comparison run

**Files:**
- Modify: `workers/api/src/twist/builder.e2e.test.ts`
- No other files; results land in gitignored `evals/results/`.

**Interfaces:**
- Consumes: everything from Tasks 1–4; Docker; `workers/api/.dev.vars`.

- [ ] **Step 1: Extend the e2e suite**

In `workers/api/src/twist/builder.e2e.test.ts`, update the result type in the existing tests to include `templateCache?: "hit" | "miss"` and append these tests inside the suite (reusing `CONTAINER_PORT`):

```ts
  it("fails a type-broken source with a Type check marker", async () => {
    const source = {
      displayName: "TypeBroken",
      dependencies: { "@plotday/twister": "latest" },
      files: {
        "index.ts": `
import { Twist, type ToolBuilder } from "@plotday/twister";

export default class TypeBroken extends Twist {
  build(_builder: ToolBuilder) {
    const n: number = "not a number";
    return {};
  }
}
`.trimStart(),
      },
    };
    const response = await fetch(`http://127.0.0.1:${CONTAINER_PORT}/build`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(source),
    });
    const result = (await response.json()) as
      | { success: true }
      | { success: false; errors: string[] };
    expect(result.success).toBe(false);
    if (!result.success) {
      expect(result.errors.join("\n")).toContain("Type check failed:");
      expect(result.errors.join("\n")).toMatch(/TS2322|not assignable/);
    }
  }, 5 * 60_000);

  it("reuses the version template on a second build (cache hit, no install)", async () => {
    const source = {
      displayName: "CacheProbe",
      dependencies: { "@plotday/twister": "latest" },
      files: {
        "index.ts": `
import { Twist, type ToolBuilder } from "@plotday/twister";

export default class CacheProbe extends Twist {
  build(_builder: ToolBuilder) {
    return {};
  }
}
`.trimStart(),
      },
    };
    const post = () =>
      fetch(`http://127.0.0.1:${CONTAINER_PORT}/build`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(source),
      }).then((r) => r.json() as Promise<{ success: boolean; templateCache?: string }>);
    const first = await post();
    expect(first.success).toBe(true);
    const started = Date.now();
    const second = await post();
    const elapsed = Date.now() - started;
    expect(second.success).toBe(true);
    expect(second.templateCache).toBe("hit");
    expect(elapsed).toBeLessThan(30_000); // no npm install on the hot path
  }, 5 * 60_000);

  it("installs model-requested extra dependencies on top of the template", async () => {
    const source = {
      displayName: "ExtraDeps",
      dependencies: { "@plotday/twister": "latest", zod: "^4.0.0" },
      files: {
        "index.ts": `
import { z } from "zod";
import { Twist, type ToolBuilder } from "@plotday/twister";

const schema = z.object({ ok: z.boolean() });

export default class ExtraDeps extends Twist {
  build(_builder: ToolBuilder) {
    schema.parse({ ok: true });
    return {};
  }
}
`.trimStart(),
      },
    };
    const response = await fetch(`http://127.0.0.1:${CONTAINER_PORT}/build`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(source),
    });
    const result = (await response.json()) as
      | { success: true; module: string }
      | { success: false; errors: string[] };
    if (!result.success) {
      throw new Error(`ExtraDeps build failed:\n${result.errors.join("\n\n")}`);
    }
    expect(result.module).toContain("ok");
  }, 5 * 60_000);
```

Also update the suite's first test ("builds a minimal twist source") to assert `expect((result as any).templateCache).toBeDefined();` after the success check, and note in the header comment that the container now typechecks (the "minimal twist" fixture must remain type-valid).

- [ ] **Step 2: Run the e2e suite (Docker required)**

Run from workers/api: `E2E_TWIST_BUILDER=1 npx vitest run src/twist/builder.e2e.test.ts --config vitest.config.ts`
Expected: all 5 tests pass (first run populates the template — the docker build itself is cached). If the "minimal twist" fixture now fails tsc (SDK type drift), fix the FIXTURE to be type-valid — do not weaken the server.

- [ ] **Step 3: Comparison run (live, ~$5, authorized)**

Prereqs: Docker up, `.dev.vars` present, `public/twister/dist` built. Run from the worktree root:

`pnpm --filter @plotday/api eval:twist-gen --label pr-a --runs 2 --compare evals/results/20260708-171348-baseline-gemini-31-pro-v2.json`

Run it in the background (30–60 min) and wait for completion. Record in your report: the scorecard, the compare output (regressions section), mean/median buildMs vs the baseline's, and the taxonomy (expect harness-level `typecheck_failed` ≈ 0; any `max_attempts_exhausted` should show `finalBuildClass: build_typecheck` where type repair failed).

Acceptance: full-pass rate ≥ 67% baseline (small sampling noise acceptable — flag anything > 8pp drop as a stop-and-report), buildMs median well under the baseline's, no new `infra`/`api_error` classes.

- [ ] **Step 4: Commit**

```bash
git add workers/api/src/twist/builder.e2e.test.ts
git commit -m "test(api): e2e coverage for template cache, typecheck failures, extra deps

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Final verification (after all tasks)

1. `npx vitest run evals/ src/twist/generator.test.ts` (workers/api) and `npm test` (container server) — green.
2. `pnpm --filter @plotday/api lint` and server `npm run build` — clean.
3. Comparison-run results JSON exists; report captures the before/after table.
4. `git log --oneline` shows 5 implementation commits + the spec/plan docs commits.
