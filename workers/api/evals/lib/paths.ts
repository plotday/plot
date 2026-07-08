import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url)); // workers/api/evals/lib

export const EVALS_DIR = join(here, "..");
export const API_ROOT = join(EVALS_DIR, "..");
export const REPO_ROOT = join(API_ROOT, "..", "..");
export const CORPUS_DIR = join(EVALS_DIR, "corpus");
export const RESULTS_DIR = join(EVALS_DIR, "results");
export const CONTAINER_DIR = join(API_ROOT, "containers", "twist-builder");
export const TWISTER_DIST = join(REPO_ROOT, "public", "twister", "dist");
export const TSCONFIG_BASE = join(
  REPO_ROOT,
  "public",
  "twister",
  "tsconfig.base.json"
);
// Root node_modules, not API_ROOT: typescript is only declared as a
// devDependency at the repo root. workers/api/node_modules/.bin/tsc happens
// to exist locally too, but only as an incidental peer-dependency artifact of
// @typescript-eslint (a different typescript version, resolved via
// auto-install-peers) — not guaranteed to be linked there in every install.
export const TSC_BIN = join(REPO_ROOT, "node_modules", ".bin", "tsc");
