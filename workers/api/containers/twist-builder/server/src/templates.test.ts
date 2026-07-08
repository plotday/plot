import { mkdtemp, readFile, readdir, mkdir, rm, writeFile, utimes } from "fs/promises";
import { tmpdir } from "os";
import { join } from "path";
import { afterEach, describe, it, expect } from "vitest";

import {
  getTemplate,
  InvalidVersionError,
  pruneTemplates,
  type Installer,
} from "./templates.js";

const tmpDirs: string[] = [];

async function freshDir(): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), "tpl-test-"));
  tmpDirs.push(dir);
  return dir;
}

afterEach(async () => {
  await Promise.all(
    tmpDirs.splice(0).map((dir) => rm(dir, { recursive: true, force: true }))
  );
});

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

  it("accepts semver build metadata in the version string", async () => {
    const dir = await freshDir();
    const calls: string[] = [];
    const result = await getTemplate("1.0.0+sha.abc", fakeInstaller(calls), dir);
    expect(result.cache).toBe("miss");
    expect(calls).toHaveLength(1);
  });

  it("rejects invalid version strings", async () => {
    const dir = await freshDir();
    await expect(
      getTemplate("1.0.0; rm -rf /", fakeInstaller([]), dir)
    ).rejects.toThrow(/Invalid twister version/);
    // The rejection must be the typed error so callers can distinguish
    // validation failures from install failures (no fallback-to-latest).
    await expect(
      getTemplate("1.0.0; rm -rf /", fakeInstaller([]), dir)
    ).rejects.toBeInstanceOf(InvalidVersionError);
  });

  it("rejects path-traversal version strings", async () => {
    // Nest the templates dir inside a sacrificial parent: if ".." were
    // accepted, getTemplate would rm -rf the parent of the templates dir.
    const base = await freshDir();
    const dir = join(base, "templates");
    await mkdir(dir, { recursive: true });
    await expect(getTemplate("..", fakeInstaller([]), dir)).rejects.toThrow(
      /Invalid twister version/
    );
    await expect(getTemplate("..", fakeInstaller([]), dir)).rejects.toBeInstanceOf(
      InvalidVersionError
    );
    await expect(getTemplate(".", fakeInstaller([]), dir)).rejects.toThrow(
      /Invalid twister version/
    );
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
