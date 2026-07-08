import { readFileSync } from "node:fs";
import { join } from "node:path";

import { API_ROOT } from "./paths";

export const REQUIRED_VARS = [
  "ANTHROPIC_API_KEY",
  "AI_GATEWAY_ACCOUNT_ID",
  "AI_GATEWAY_ID",
  "AI_GATEWAY_TOKEN",
] as const;

export function loadDevVars(
  path: string = join(API_ROOT, ".dev.vars")
): Record<string, string> {
  const out: Record<string, string> = {};
  const raw = readFileSync(path, "utf-8");
  for (const rawLine of raw.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const eq = line.indexOf("=");
    if (eq === -1) continue;
    const key = line.slice(0, eq).trim();
    let value = line.slice(eq + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    out[key] = value;
  }
  return out;
}

export function assertRequiredVars(vars: Record<string, string>): void {
  const missing = REQUIRED_VARS.filter((key) => !vars[key]);
  if (missing.length > 0) {
    throw new Error(
      `Missing in workers/api/.dev.vars: ${missing.join(", ")} — ` +
        `run 'pnpm --filter @plotday/api get-env' (or 'pnpm cp-env <main-repo>' in a worktree)`
    );
  }
}

/**
 * Minimal TWIST_BUILDER stand-in matching the subset @cloudflare/containers
 * uses: getContainer() reads idFromName() + get() off the namespace and
 * calls fetch() on the returned stub.
 */
function containerBinding(port: number) {
  const stub = {
    fetch(_url: string, init?: RequestInit) {
      return fetch(`http://127.0.0.1:${port}/build`, init);
    },
  };
  return { idFromName: () => ({}), get: () => stub };
}

/**
 * Deliberately minimal: ONLY what generateTwist() reads. In particular no
 * POSTHOG_API_KEY — eval failures are intentional data, not production
 * incidents, and must never reach PostHog error tracking.
 */
export function buildEvalEnv(
  vars: Record<string, string>,
  containerPort: number
): Record<string, unknown> {
  return {
    ANTHROPIC_API_KEY: vars.ANTHROPIC_API_KEY,
    AI_GATEWAY_ACCOUNT_ID: vars.AI_GATEWAY_ACCOUNT_ID,
    AI_GATEWAY_ID: vars.AI_GATEWAY_ID,
    AI_GATEWAY_TOKEN: vars.AI_GATEWAY_TOKEN,
    TWIST_BUILDER: containerBinding(containerPort),
  };
}
