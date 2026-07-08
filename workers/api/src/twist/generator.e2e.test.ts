/**
 * Full end-to-end test of spec-driven twist generation.
 *
 * Opt-in: set E2E_TWIST_GENERATE=1 to run. Skipped by default.
 *
 * Prerequisites
 *   - Docker running (container builder is booted locally).
 *   - workers/api/.dev.vars populated with GOOGLE_GENERATIVE_AI_API_KEY,
 *     AI_GATEWAY_ACCOUNT_ID, AI_GATEWAY_ID, AI_GATEWAY_TOKEN. The test loads
 *     them automatically, so no env setup is required beyond the opt-in flag.
 *
 * What it covers
 *   Feeds a real spec to `generateTwist()`, which calls the default model's
 *   provider through the Cloudflare AI Gateway and bundles the result inside
 *   the twist-builder container. This is the same pipeline
 *   `POST /v1/twist/generate` serves in production. If this passes, the
 *   whole path — prompt shape, schema validation, retry loop, container
 *   build — works against the live SDK.
 *
 * Running
 *   E2E_TWIST_GENERATE=1 pnpm -F @plotday/api test -- generator.e2e
 */

import { readFileSync } from "node:fs";
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { randomBytes } from "node:crypto";
import { afterAll, beforeAll, describe, it, expect } from "vitest";

import { generateTwist } from "./generator";
import type { Bindings } from "../env";

const shouldRun = process.env.E2E_TWIST_GENERATE === "1";
const suite = shouldRun ? describe : describe.skip;

const IMAGE_TAG = "plot-twist-builder-e2e:test";
const CONTAINER_NAME = `plot-twist-generate-e2e-${randomBytes(4).toString("hex")}`;
const CONTAINER_PORT = 13001;
const DOCKERFILE_DIR = new URL(
  "../../containers/twist-builder/",
  import.meta.url
).pathname;
const DEV_VARS_PATH = new URL("../../.dev.vars", import.meta.url).pathname;

function loadDevVars(): Record<string, string> {
  const out: Record<string, string> = {};
  const raw = readFileSync(DEV_VARS_PATH, "utf-8");
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

function dockerSync(args: string[]): { status: number; stderr: string } {
  const r = spawnSync("docker", args, { stdio: ["ignore", "inherit", "pipe"] });
  return { status: r.status ?? -1, stderr: r.stderr?.toString() ?? "" };
}

async function waitForHealth(port: number, timeoutMs = 60_000) {
  const deadline = Date.now() + timeoutMs;
  let lastError: unknown;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`http://127.0.0.1:${port}/health`);
      if (res.ok) return;
    } catch (e) {
      lastError = e;
    }
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error(
    `Container did not become healthy within ${timeoutMs}ms: ${String(lastError)}`
  );
}

/**
 * Minimal TWIST_BUILDER stand-in for Node-side tests. In production this is a
 * Durable Object container namespace; here we expose the same surface
 * `buildTwist()` uses (`getContainer(...).fetch(...)`) by forwarding to the
 * locally-running Docker container.
 */
function containerBindingForLocalDocker(port: number) {
  // Shape matches the subset `@cloudflare/containers` uses: `getContainer`
  // reads `.idFromName()` + `.get()` off the namespace and calls `.fetch()` on
  // the returned stub.
  const stub = {
    fetch(_url: string, init?: RequestInit) {
      return fetch(`http://127.0.0.1:${port}/build`, init);
    },
  };
  return {
    idFromName: () => ({}),
    get: () => stub,
  };
}

suite("spec-driven twist generation (E2E)", () => {
  let containerProc: ChildProcess | null = null;
  let env: Bindings;

  beforeAll(async () => {
    const vars = loadDevVars();
    for (const required of [
      "GOOGLE_GENERATIVE_AI_API_KEY",
      "AI_GATEWAY_ACCOUNT_ID",
      "AI_GATEWAY_ID",
      "AI_GATEWAY_TOKEN",
    ]) {
      if (!vars[required]) {
        throw new Error(`Missing ${required} in ${DEV_VARS_PATH}`);
      }
    }

    const build = dockerSync(["build", "-t", IMAGE_TAG, DOCKERFILE_DIR]);
    if (build.status !== 0) {
      throw new Error(`docker build failed:\n${build.stderr}`);
    }

    containerProc = spawn(
      "docker",
      [
        "run",
        "--rm",
        "--name",
        CONTAINER_NAME,
        "-p",
        `${CONTAINER_PORT}:3000`,
        IMAGE_TAG,
      ],
      { stdio: ["ignore", "inherit", "inherit"] }
    );

    await waitForHealth(CONTAINER_PORT);

    env = {
      ANTHROPIC_API_KEY: vars.ANTHROPIC_API_KEY,
      GOOGLE_GENERATIVE_AI_API_KEY: vars.GOOGLE_GENERATIVE_AI_API_KEY,
      AI_GATEWAY_ACCOUNT_ID: vars.AI_GATEWAY_ACCOUNT_ID,
      AI_GATEWAY_ID: vars.AI_GATEWAY_ID,
      AI_GATEWAY_TOKEN: vars.AI_GATEWAY_TOKEN,
      TWIST_BUILDER: containerBindingForLocalDocker(CONTAINER_PORT),
    } as unknown as Bindings;
  }, 10 * 60_000);

  afterAll(() => {
    dockerSync(["stop", CONTAINER_NAME]);
    containerProc?.kill("SIGKILL");
  });

  it("generates, validates, and builds a twist from a natural-language spec", async () => {
    const spec = `
# Hello Thread Twist

When the user activates this twist on a priority, create a single thread
titled "Hello from Twister E2E" with a short markdown note that says "This
twist was generated by the spec-driven pipeline." Do nothing on deactivate or
upgrade.
`.trim();

    const progress: string[] = [];
    const source = await generateTwist({
      spec,
      env,
      onProgress: (msg) => progress.push(msg),
    });

    // Shape checks — the Zod schema inside generateTwist already enforces
    // these, but asserting again makes the failure mode obvious if the SDK
    // or schema changes.
    expect(source.displayName).toBeTruthy();
    expect(source.files["index.ts"]).toBeTruthy();
    expect(source.dependencies["@plotday/twister"]).toBe("latest");
    expect(source.files["index.ts"]).toMatch(/class\s+\w+\s+extends\s+Twist/);

    // generateTwist() already called the container to build successfully — if
    // it returned, the build passed. Progress callback should reflect that.
    expect(progress).toContain("Generating twist code");
    expect(progress).toContain("Building twist code");
  }, 8 * 60_000);
});
