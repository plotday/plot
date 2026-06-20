import { describe, it, expect, vi, beforeEach } from "vitest";

import worker from "./index";
import { handleClassifyJob, parkUnclassifiable } from "./handler";

// Hoisted PostHog spies shared with the module mock below.
const { captureException, capture, shutdown } = vi.hoisted(() => ({
  captureException: vi.fn(),
  capture: vi.fn(),
  shutdown: vi.fn(async () => {}),
}));

vi.mock("posthog-node", () => ({
  PostHog: vi.fn().mockImplementation(() => ({
    captureException,
    capture,
    shutdown,
  })),
}));

vi.mock("@plotday/worker-util", () => ({
  createLogger: () => ({ warn: vi.fn(), error: vi.fn(), info: vi.fn() }),
}));

// Keep the real isLockTimeoutError; stub withDb to run the callback with a
// dummy db handle so the queue handler exercises its per-message try/catch.
vi.mock("./db", async (importActual) => {
  const actual = (await importActual()) as Record<string, unknown>;
  return {
    ...actual,
    withDb: vi.fn(async (_env: unknown, fn: (db: unknown) => Promise<unknown>) =>
      fn({})
    ),
  };
});

vi.mock("./handler", () => ({
  handleClassifyJob: vi.fn(),
  parkUnclassifiable: vi.fn(),
}));

const handleMock = handleClassifyJob as unknown as ReturnType<typeof vi.fn>;
const parkMock = parkUnclassifiable as unknown as ReturnType<typeof vi.fn>;

function pgError(message: string, code: string): Error & { code: string } {
  const e = new Error(message) as Error & { code: string };
  e.code = code;
  return e;
}

function makeMessage(threadId: string, attempts = 1) {
  return {
    body: { userId: "u1", threadId },
    attempts,
    ack: vi.fn(),
    retry: vi.fn(),
  };
}

const env = {
  POSTHOG_API_KEY: "key",
  POSTHOG_HOST: "host",
} as never;

function runBatch(messages: ReturnType<typeof makeMessage>[]) {
  const ctx = { waitUntil: vi.fn() } as never;
  return worker.queue({ messages } as never, env, ctx);
}

beforeEach(() => {
  vi.clearAllMocks();
  parkMock.mockResolvedValue(true);
});

describe("classify queue consumer error handling", () => {
  it("treats a lock_timeout (55P03) as expected: retry without capturing", async () => {
    handleMock.mockRejectedValueOnce(
      pgError("canceling statement due to lock timeout", "55P03")
    );
    const msg = makeMessage("t-contended");

    await runBatch([msg]);

    expect(captureException).not.toHaveBeenCalled();
    expect(msg.retry).toHaveBeenCalledTimes(1);
    expect(msg.ack).not.toHaveBeenCalled();
  });

  it("defers a statement_timeout (57014) to the hourly sweep: emits a counter event and acks, without capturing it as a bug", async () => {
    // A 57014 here is transient DB saturation, not a slow query, and we
    // deliberately DEFER it: ack so the queue stops re-delivering, leave
    // classify_at set so the next hourly sweep re-enqueues it once contention
    // clears. That makes it an expected, handled, self-healing condition — like
    // the 55P03 branch above — so it must NOT be reported to error tracking.
    // Capturing it once per thread on every hourly sweep is exactly what kept
    // PostHog 019ed53e firing indefinitely after the deferral shipped. Emit a
    // queryable counter event instead so saturation stays observable.
    handleMock.mockRejectedValueOnce(
      pgError("canceling statement due to statement timeout", "57014")
    );
    const msg = makeMessage("t-saturated");

    await runBatch([msg]);

    expect(captureException).not.toHaveBeenCalled();
    expect(capture).toHaveBeenCalledWith(
      expect.objectContaining({ event: "classify.deferred_timeout" })
    );
    expect(msg.ack).toHaveBeenCalledTimes(1);
    expect(msg.retry).not.toHaveBeenCalled();
  });

  it("captures other unexpected errors and retries", async () => {
    handleMock.mockRejectedValueOnce(new Error("boom"));
    const msg = makeMessage("t-bug");

    await runBatch([msg]);

    expect(captureException).toHaveBeenCalledTimes(1);
    expect(msg.retry).toHaveBeenCalledTimes(1);
  });

  it("acks a successful job and emits classify.handled telemetry", async () => {
    handleMock.mockResolvedValueOnce({ status: "same", stage: "test" });
    const msg = makeMessage("t-ok");

    await runBatch([msg]);

    expect(msg.ack).toHaveBeenCalledTimes(1);
    expect(msg.retry).not.toHaveBeenCalled();
    expect(captureException).not.toHaveBeenCalled();
    expect(capture).toHaveBeenCalledWith(
      expect.objectContaining({ event: "classify.handled" })
    );
  });

  it("parks the thread and acks (no retry) once queue retries are exhausted", async () => {
    handleMock.mockRejectedValue(
      pgError("canceling statement due to statement timeout", "57014")
    );
    const msg = makeMessage("t-stuck", 4);

    await runBatch([msg]);

    expect(parkMock).toHaveBeenCalledWith(expect.anything(), msg.body);
    expect(msg.ack).toHaveBeenCalledTimes(1);
    expect(msg.retry).not.toHaveBeenCalled();
    // Observable give-up signal instead of an infinite error stream.
    expect(capture).toHaveBeenCalledWith(
      expect.objectContaining({ event: "classify.gave_up" })
    );
  });

  it("retries a non-terminal error (does not park) while attempts remain", async () => {
    handleMock.mockRejectedValue(new Error("boom"));
    const msg = makeMessage("t-early", 1);

    await runBatch([msg]);

    expect(parkMock).not.toHaveBeenCalled();
    expect(msg.retry).toHaveBeenCalledTimes(1);
    expect(msg.ack).not.toHaveBeenCalled();
  });

  it("parks a thread stuck on sustained lock contention once retries are exhausted, without capturing it as a bug", async () => {
    handleMock.mockRejectedValue(
      pgError("canceling statement due to lock timeout", "55P03")
    );
    const msg = makeMessage("t-locked", 4);

    await runBatch([msg]);

    expect(parkMock).toHaveBeenCalledTimes(1);
    expect(msg.ack).toHaveBeenCalledTimes(1);
    expect(msg.retry).not.toHaveBeenCalled();
    expect(captureException).not.toHaveBeenCalled();
  });

  it("retries when parking itself fails so the job is not silently dropped", async () => {
    handleMock.mockRejectedValue(
      pgError("canceling statement due to statement timeout", "57014")
    );
    parkMock.mockRejectedValueOnce(new Error("park update timed out"));
    const msg = makeMessage("t-park-fail", 4);

    await runBatch([msg]);

    expect(msg.retry).toHaveBeenCalledTimes(1);
    expect(msg.ack).not.toHaveBeenCalled();
  });

  it("isolates failures per message within a batch", async () => {
    handleMock
      .mockRejectedValueOnce(
        pgError("canceling statement due to lock timeout", "55P03")
      )
      .mockResolvedValueOnce({ status: "settled", stage: "test" });
    const contended = makeMessage("t-a");
    const ok = makeMessage("t-b");

    await runBatch([contended, ok]);

    expect(contended.retry).toHaveBeenCalledTimes(1);
    expect(ok.ack).toHaveBeenCalledTimes(1);
    expect(captureException).not.toHaveBeenCalled();
  });
});
