import { exec } from "child_process";
import { mkdir, readdir, rm, stat, utimes, writeFile } from "fs/promises";
import { isAbsolute, join, relative } from "path";
import { promisify } from "util";

const execAsync = promisify(exec);

export const TEMPLATES_DIR = process.env.TEMPLATES_DIR ?? "/templates";
const MAX_TEMPLATES = 4;

export type Installer = (dir: string) => Promise<void>;

/**
 * Thrown when a requested twister version fails validation (as opposed to
 * failing to install). Callers should reject these outright rather than
 * falling back to another version.
 */
export class InvalidVersionError extends Error {}

export interface TemplateResult {
  dir: string;
  cache: "hit" | "miss";
}

const defaultInstaller: Installer = async (dir) => {
  // --ignore-scripts: template node_modules is only used for type/bundle
  // resolution — nothing executes from it — so lifecycle scripts of
  // model-chosen packages are pure attack surface.
  await execAsync(`cd "${dir}" && npm install --no-audit --no-fund --ignore-scripts`, {
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
  if (!/^[0-9A-Za-z.+\-]+$/.test(version) || version === "." || version === "..") {
    throw new InvalidVersionError(`Invalid twister version: ${version}`);
  }
  const dir = join(templatesDir, version);
  // Belt and braces: the resolved dir must stay inside templatesDir, so a
  // traversal that slipped past the regex can never rm/populate outside it.
  const rel = relative(templatesDir, dir);
  if (rel.startsWith("..") || isAbsolute(rel) || rel.length === 0) {
    throw new InvalidVersionError(`Invalid twister version: ${version}`);
  }
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
