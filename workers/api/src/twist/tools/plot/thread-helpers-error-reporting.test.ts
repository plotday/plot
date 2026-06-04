import { describe, it, expect, vi, beforeEach } from "vitest";

import { DbError } from "@plotday/db";

import { handleDbOperationError } from "./thread-helpers";

// Spy on the PostHog node client so we can assert Error Tracking reporting
// without touching the network. Declared via vi.hoisted so the spies exist
// when vitest lifts the vi.mock factory above the imports.
const { captureException, shutdown } = vi.hoisted(() => ({
  captureException: vi.fn(),
  shutdown: vi.fn().mockResolvedValue(undefined),
}));
vi.mock("posthog-node", () => ({
  PostHog: vi.fn().mockImplementation(() => ({ captureException, shutdown })),
}));

// Minimal Plot stand-in: handleDbOperationError only needs env, the twist id,
// and getUserId for the distinct id.
const fakePlot = {
  twistInstanceId: "twist-1",
  env: { POSTHOG_API_KEY: "key", POSTHOG_HOST: "https://posthog.test" },
  getUserId: vi.fn().mockResolvedValue("user-1"),
} as unknown as Parameters<typeof handleDbOperationError>[2];

describe("handleDbOperationError", () => {
  beforeEach(() => {
    captureException.mockClear();
    shutdown.mockClear();
  });

  it("reports an unexpected DbError to PostHog Error Tracking and throws a sanitized error", async () => {
    // Mirrors the real incident: a schedule write rejected by a trigger.
    const dbErr = new DbError({
      message: "column n.user_id does not exist",
      code: "42703",
    } as never);

    await expect(
      handleDbOperationError(dbErr, "createLink", fakePlot, { has_notes: true })
    ).rejects.toThrow("Something went wrong");

    expect(captureException).toHaveBeenCalledTimes(1);
    expect(captureException).toHaveBeenCalledWith(
      dbErr,
      "user-1",
      expect.objectContaining({
        context: "plot:createLink",
        twist_instance_id: "twist-1",
        db_code: "42703",
        has_notes: true,
      })
    );
    // The flush must be awaited so the event is delivered before the worker ends.
    expect(shutdown).toHaveBeenCalledTimes(1);
  });

  it("rethrows expected (non-DbError) errors unchanged and does not report them", async () => {
    const expected = new Error("validation failed");

    await expect(
      handleDbOperationError(expected, "createLink", fakePlot, {})
    ).rejects.toBe(expected);

    expect(captureException).not.toHaveBeenCalled();
    expect(shutdown).not.toHaveBeenCalled();
  });

  it("still throws the sanitized error even if PostHog reporting fails", async () => {
    captureException.mockImplementationOnce(() => {
      throw new Error("posthog unreachable");
    });
    const dbErr = new DbError({ message: "boom", code: "XX000" } as never);

    await expect(
      handleDbOperationError(dbErr, "createThread", fakePlot, {})
    ).rejects.toThrow("Something went wrong");
  });
});
