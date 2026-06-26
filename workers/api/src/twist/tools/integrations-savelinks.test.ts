import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

import { Integrations } from "./integrations";

// saveLinks only touches `this.saveLink`, so we can exercise its batch
// failure-handling against a stubbed saveLink without a DB.
function runSaveLinks(
  saveLink: (link: any) => Promise<any>,
  links: any[]
): Promise<(string | null)[]> {
  const fakeThis = { saveLink } as unknown as Integrations;
  return (Integrations.prototype.saveLinks as any).call(fakeThis, links);
}

const poolError = () =>
  new Error("Timed out while waiting for an open slot in the pool.");

describe("Integrations.saveLinks failure handling", () => {
  // The permanent-failure path logs via console.error; keep test output clean.
  let errSpy: ReturnType<typeof vi.spyOn>;
  beforeEach(() => {
    errSpy = vi.spyOn(console, "error").mockImplementation(() => {});
  });
  afterEach(() => errSpy.mockRestore());

  it("swallows a per-item permanent failure as null without aborting the batch", async () => {
    const saveLink = vi.fn(async (link: any) => {
      if (link.source === "bad") throw new Error("duplicate key value");
      return link.source;
    });
    const out = await runSaveLinks(saveLink, [
      { source: "a" },
      { source: "bad" },
      { source: "c" },
    ]);
    // One malformed item must not lose the rest of the page.
    expect(out).toEqual(["a", null, "c"]);
  });

  it("propagates a transient pool-exhaustion failure so the run-queue re-runs the idempotent sync", async () => {
    const saveLink = vi.fn(async (link: any) => {
      if (link.source === "boom") throw poolError();
      return link.source;
    });
    await expect(
      runSaveLinks(saveLink, [{ source: "a" }, { source: "boom" }])
    ).rejects.toThrow("open slot in the pool");
  });

  it("propagates a transient failure wrapped in a DbError cause chain", async () => {
    const saveLink = vi.fn(async () => {
      const e = new Error("Database query failed") as Error & { cause?: unknown };
      e.cause = poolError();
      throw e;
    });
    await expect(runSaveLinks(saveLink, [{ source: "x" }])).rejects.toThrow();
  });

  it("returns all ids when every link succeeds", async () => {
    const saveLink = vi.fn(async (link: any) => link.source);
    await expect(
      runSaveLinks(saveLink, [{ source: "a" }, { source: "b" }])
    ).resolves.toEqual(["a", "b"]);
  });
});
