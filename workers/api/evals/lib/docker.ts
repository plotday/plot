import { execFileSync, spawnSync } from "node:child_process";
import { createServer } from "node:net";

import { CONTAINER_DIR } from "./paths";
import { EvalInfraError } from "./types";

export const IMAGE_TAG = "plot-twist-builder-eval";

export function assertDockerAvailable(): void {
  const result = spawnSync("docker", ["info"], { stdio: "ignore" });
  if (result.status !== 0) {
    throw new EvalInfraError(
      "Docker daemon not reachable — start Docker Desktop and retry."
    );
  }
}

export function buildImage(): void {
  execFileSync("docker", ["build", "-t", IMAGE_TAG, CONTAINER_DIR], {
    stdio: "inherit",
  });
}

export async function findFreePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.on("error", reject);
    server.listen(0, () => {
      const address = server.address();
      if (typeof address === "object" && address) {
        const port = address.port;
        server.close(() => resolve(port));
      } else {
        server.close(() => reject(new Error("could not allocate a port")));
      }
    });
  });
}

export function startContainer(port: number): string {
  const name = `plot-twist-eval-${Date.now().toString(36)}`;
  execFileSync(
    "docker",
    ["run", "-d", "--rm", "--name", name, "-p", `${port}:3000`, IMAGE_TAG],
    { stdio: "ignore" }
  );
  return name;
}

export async function waitForHealth(port: number, timeoutMs = 60_000): Promise<void> {
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
  throw new EvalInfraError(
    `twist-builder container not healthy within ${timeoutMs}ms: ${String(lastError)}`
  );
}

export function stopContainer(name: string): void {
  spawnSync("docker", ["stop", name], { stdio: "ignore" });
}
