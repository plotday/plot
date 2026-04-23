/**
 * End-to-end test of the twist-builder container.
 *
 * Opt-in: set E2E_TWIST_BUILDER=1 to run. Skipped by default because it:
 *   - Requires Docker on the host.
 *   - Builds the container image (slow on first run; cached after).
 *   - Runs a full `npm install` + `plot build` inside the container (~1–2 min).
 *
 * What it covers
 *   Spec-driven twist generation produces a TwistSource and feeds it to
 *   buildTwist(), which forwards it to a container running
 *   `containers/twist-builder/server`. This test sends a hand-crafted minimal
 *   TwistSource directly to that server's /build endpoint — the same shape the
 *   generator produces on a happy path — and asserts we get a bundled module
 *   back. If this passes, the generator's output will build too, provided the
 *   model emits syntactically valid code against the current @plotday/twister.
 *
 * Running
 *   E2E_TWIST_BUILDER=1 pnpm -F @plotday/api test -- builder.e2e
 */

import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { randomBytes } from "node:crypto";
import { afterAll, beforeAll, describe, it, expect } from "vitest";

const shouldRun = process.env.E2E_TWIST_BUILDER === "1";
const suite = shouldRun ? describe : describe.skip;

const IMAGE_TAG = "plot-twist-builder-e2e:test";
const CONTAINER_NAME = `plot-twist-builder-e2e-${randomBytes(4).toString("hex")}`;
const CONTAINER_PORT = 13000;
const DOCKERFILE_DIR = new URL(
  "../../containers/twist-builder/",
  import.meta.url
).pathname;

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

suite("twist-builder container (E2E)", () => {
  let containerProc: ChildProcess | null = null;

  beforeAll(async () => {
    const build = dockerSync([
      "build",
      "-t",
      IMAGE_TAG,
      DOCKERFILE_DIR,
    ]);
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
  }, 10 * 60_000);

  afterAll(() => {
    dockerSync(["stop", CONTAINER_NAME]);
    containerProc?.kill("SIGKILL");
  });

  it("builds a minimal twist source", async () => {
    const source = {
      displayName: "Minimal E2E Twist",
      dependencies: {
        "@plotday/twister": "latest",
      },
      files: {
        "index.ts": `
import { Twist, type ToolBuilder } from "@plotday/twister";

export default class MinimalTwist extends Twist {
  build(_builder: ToolBuilder) {
    return {};
  }

  async activate() {}
  async deactivate() {}
  async upgrade() {}
}
`.trimStart(),
      },
    };

    const response = await fetch(
      `http://127.0.0.1:${CONTAINER_PORT}/build`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(source),
      }
    );

    expect(response.ok).toBe(true);
    const result = (await response.json()) as
      | { success: true; module: string; sourcemap?: string }
      | { success: false; errors: string[] };

    if (!result.success) {
      throw new Error(
        `Build failed unexpectedly:\n${result.errors.join("\n\n")}`
      );
    }
    expect(result.module.length).toBeGreaterThan(100);
  }, 5 * 60_000);

  it("surfaces build errors for invalid source", async () => {
    const source = {
      displayName: "Broken",
      dependencies: { "@plotday/twister": "latest" },
      files: {
        "index.ts": "this is not valid typescript !!! } {",
      },
    };

    const response = await fetch(
      `http://127.0.0.1:${CONTAINER_PORT}/build`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(source),
      }
    );

    const result = (await response.json()) as
      | { success: true; module: string }
      | { success: false; errors: string[] };

    expect(result.success).toBe(false);
    if (!result.success) {
      expect(result.errors.join("\n")).toMatch(/\w/);
    }
  }, 2 * 60_000);
});
