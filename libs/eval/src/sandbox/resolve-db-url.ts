import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const DEFAULT_PORT = 54322;
const MAX_WALK_UP = 10;

/**
 * Resolve the Postgres URL the sandbox should connect to.
 *
 * Order:
 *   1. $DATABASE_URL when set in the environment (matches what the rest of
 *      the monorepo's tooling expects).
 *   2. Repo-root .worktree-db — when in a git worktree, libs/db writes the
 *      worktree's isolated PG port there. Read PORT and build the URL.
 *   3. The main-repo default port 54322.
 *
 * Lets `pnpm run eval` work out of the box from any worktree without forcing
 * the caller to wire DATABASE_URL through pnpm's subshell env.
 */
export function resolveDatabaseUrl(): string {
  if (process.env.DATABASE_URL) return process.env.DATABASE_URL;
  const port = readWorktreePort() ?? DEFAULT_PORT;
  return `postgres://postgres:postgres@127.0.0.1:${port}/postgres`;
}

function readWorktreePort(): number | null {
  const root = findRepoRoot();
  if (!root) return null;
  try {
    const content = readFileSync(join(root, ".worktree-db"), "utf-8");
    const m = content.match(/^\s*PORT\s*=\s*(\d+)/m);
    return m ? Number(m[1]) : null;
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === "ENOENT") return null;
    throw err;
  }
}

function findRepoRoot(): string | null {
  let dir = dirname(fileURLToPath(import.meta.url));
  for (let i = 0; i < MAX_WALK_UP; i++) {
    try {
      readFileSync(join(dir, "pnpm-workspace.yaml"));
      return dir;
    } catch {
      const parent = dirname(dir);
      if (parent === dir) return null;
      dir = parent;
    }
  }
  return null;
}
