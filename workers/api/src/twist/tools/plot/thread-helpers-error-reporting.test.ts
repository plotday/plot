import { describe, it, expect, vi, beforeEach } from "vitest";

import { DbError } from "@plotday/db";

import { handleDbOperationError } from "./thread-helpers";

// Spy on the PostHog node client so we can assert Error Tracking reporting
// without touching the network. Declared via vi.hoisted so the spies exist
// when vitest lifts the vi.mock factory above the imports.
const { captureException, capture, shutdown } = vi.hoisted(() => ({
  captureException: vi.fn(),
  capture: vi.fn(),
  shutdown: vi.fn().mockResolvedValue(undefined),
}));
vi.mock("posthog-node", () => ({
  PostHog: vi
    .fn()
    .mockImplementation(() => ({ captureException, capture, shutdown })),
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
    capture.mockClear();
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

  it("rethrows a lock-contention statement timeout (57014) unchanged, does not page Error Tracking, but emits a low-cardinality metric", async () => {
    // A concurrent long transaction holds a per-user hot row (e.g. user_sync),
    // so upsert_thread blocks and hits statement_timeout. This is transient and
    // self-healing (the connector re-syncs next cycle), so it must NOT page
    // Error Tracking — PostHog 019f1aec was 58 of these for a single burst —
    // but a sustained burst must still be visible, so we emit one bounded
    // analytics event instead.
    const timeout = new DbError({
      message: "canceling statement due to statement timeout",
      code: "57014",
    } as never);

    await expect(
      handleDbOperationError(timeout, "createLink", fakePlot, {})
    ).rejects.toBe(timeout);

    // Not reported as a bug.
    expect(captureException).not.toHaveBeenCalled();
    // Counted as a low-cardinality metric (no per-thread payload).
    expect(capture).toHaveBeenCalledTimes(1);
    expect(capture).toHaveBeenCalledWith({
      distinctId: "user-1",
      event: "db.lock_contention_timeout",
      properties: {
        operation: "createLink",
        pg_code: "57014",
        provider: null,
      },
    });
    // The flush must be awaited so the event is delivered before the worker ends.
    expect(shutdown).toHaveBeenCalledTimes(1);
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
