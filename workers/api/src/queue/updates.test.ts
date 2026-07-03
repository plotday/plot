import { beforeEach, describe, expect, it, vi } from "vitest";

import type { PostHog } from "posthog-node";
import type { TwistBatchMessage } from "../env";

import {
  captureTwistBatchError,
  isRetriableDispatchError,
  processUpdates,
} from "./updates";

// Shared mutable holders the hoisted vi.mock factories read from, so each test
// can swap the fake db / dispatch behaviour without re-registering the mock.
const h = vi.hoisted(() => ({
  currentDb: null as any,
  dispatch: null as any,
}));

// Keep the real transient-error classifiers (isTransientDbError etc.) — only
// stub createDb so processTwistBatch runs against a fake handle.
vi.mock("../db", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../db")>();
  return { ...actual, createDb: () => h.currentDb };
});

// twistFactory → a wrapper whose dispatch() the test controls. This is the
// connector write-back hop that faults during a DO storage reset.
vi.mock("../twist", () => ({
  twistFactory: () => async () => ({
    dispatch: (...args: unknown[]) => h.dispatch(...args),
  }),
}));

// Quota check always passes so the batch reaches the dispatch loop.
vi.mock("../state/usage", () => ({
  Usage: { Get: () => ({ checkExecutionQuota: async () => true }) },
}));

function makePostHog() {
  const captureException = vi.fn();
  return {
    postHog: { captureException } as unknown as PostHog,
    captureException,
  };
}

describe("captureTwistBatchError suppresses expected infra/provider blips", () => {
  it("skips a Durable Object storage-startup reset wrapped as a TwistError", () => {
    // The updates-queue path wraps connector-callback throws in a
    // `__TWIST_ERROR__` envelope as they cross the twist RPC boundary, so the
    // Cloudflare marker is embedded as a substring. isTransientDoResetError
    // still matches it. Without this the fault was captured once per affected
    // item (PostHog issue 019f277a: 30 captures from Google.onThreadRead).
    const { postHog, captureException } = makePostHog();
    captureTwistBatchError(
      postHog,
      new Error(
        'TwistError: __TWIST_ERROR__{"message":"Internal error while starting ' +
          'up Durable Object storage caused object to be reset; reference = ' +
          'imgca96kon4vhhsprpjhpbdo","operation":"dispatch: onThreadRead"}'
      ),
      "user-1",
      { queue: "twist-batch" }
    );
    expect(captureException).not.toHaveBeenCalled();
  });

  it("skips downstream rate-limit and terminal auth errors", () => {
    const { postHog, captureException } = makePostHog();
    captureTwistBatchError(
      postHog,
      new Error("Gmail API error: 403 - rateLimitExceeded"),
      "user-1",
      {}
    );
    captureTwistBatchError(
      postHog,
      new Error("401 Unauthorized - Invalid Credentials"),
      "user-1",
      {}
    );
    expect(captureException).not.toHaveBeenCalled();
  });

  it("captures a genuine connector bug", () => {
    const { postHog, captureException } = makePostHog();
    const bug = new Error("Cannot read properties of undefined (reading 'id')");
    captureTwistBatchError(postHog, bug, "user-1", { queue: "twist-batch" });
    expect(captureException).toHaveBeenCalledTimes(1);
    expect(captureException).toHaveBeenCalledWith(bug, "user-1", {
      queue: "twist-batch",
    });
  });
});

describe("isRetriableDispatchError marks infra faults for redelivery", () => {
  it("matches the transient infrastructure faults the other consumers retry", () => {
    for (const msg of [
      // Durable Object storage reset (the write-back symptom), incl. the
      // __TWIST_ERROR__-wrapped form.
      "Internal error while starting up Durable Object storage caused object to be reset",
      'TwistError: __TWIST_ERROR__{"message":"Internal error in Durable Object storage caused object to be reset; reference = x"}',
      "Durable Object storage operation exceeded timeout which caused object to be reset",
      // Hyperdrive / pg connection drop.
      "Connection terminated unexpectedly",
      "Timed out while waiting for an open slot in the pool.",
      // Isolate OOM / network blip / deploy-time DO code swap.
      "Worker exceeded memory limit",
      "Network connection lost",
      "Durable Object reset because its code was updated",
    ]) {
      expect(isRetriableDispatchError(new Error(msg))).toBe(true);
    }
  });

  it("does NOT retry provider rate-limits, terminal auth, or genuine bugs", () => {
    for (const msg of [
      "Gmail API error: 403 - rateLimitExceeded",
      "401 Unauthorized - Invalid Credentials",
      "Cannot read properties of undefined (reading 'id')",
    ]) {
      expect(isRetriableDispatchError(new Error(msg))).toBe(false);
    }
  });
});

// A chainable Kysely-ish stub: every builder method returns itself, and the
// terminal executeTakeFirst() resolves the configured twist_instance row (or
// throws the configured error to simulate a pre-dispatch DB failure).
function makeFakeDb(opts: { twistStatus?: unknown; twistStatusError?: Error }) {
  const q: any = {
    selectFrom: () => q,
    innerJoin: () => q,
    select: () => q,
    where: () => q,
    async executeTakeFirst() {
      if (opts.twistStatusError) throw opts.twistStatusError;
      return opts.twistStatus;
    },
  };
  return { selectFrom: () => q, destroy: async () => {} };
}

type FakeMessage = {
  attempts: number;
  body: TwistBatchMessage;
  ack: ReturnType<typeof vi.fn>;
  retry: ReturnType<typeof vi.fn>;
};

function makeMessage(
  body: Partial<TwistBatchMessage>,
  attempts = 1
): FakeMessage {
  return {
    attempts,
    body: {
      twistInstanceId: "ti-1",
      twistId: 42,
      environment: "development",
      version: "1.0.0",
      newNotes: [],
      updatedNotes: [],
      updatedThreads: [],
      threadTagChanges: [],
      channelNewLinks: [],
      channelUpdatedLinks: [],
      channelNewNotes: [],
      threadReads: [],
      threadSchedules: [],
      ...body,
    } as unknown as TwistBatchMessage,
    ack: vi.fn(),
    retry: vi.fn(),
  };
}

/**
 * The reliability contract this whole change exists to enforce: a connector
 * write-back callback (onThreadRead → Gmail "remove UNREAD", onThreadToDo,
 * onNoteCreated, …) that fails on a TRANSIENT Cloudflare fault must be
 * redelivered by the queue, not silently ACKed-and-dropped. Genuine per-item
 * bugs must still be isolated so one bad item can't wedge the batch, and the
 * updates queue has NO dead-letter queue, so an exhausted transient must be
 * reported exactly once rather than vanishing.
 */
describe("processUpdates redelivers transient write-back failures", () => {
  const baseTwistStatus = {
    suspended_at: null,
    owner_id: "owner-1",
    execution_limit: 1000,
  };
  // The Cloudflare marker as it surfaces across the twist RPC boundary.
  const doResetError = new Error(
    "dispatch: onThreadRead — Internal error while starting up Durable " +
      "Object storage caused object to be reset; reference = abc123"
  );
  const threadReadBatch = {
    threadReads: [{ thread_id: "t-1", user_id: "owner-1" }] as any,
  };
  let postHog: PostHog;
  let captureException: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    ({ postHog, captureException } = makePostHog());
    h.currentDb = makeFakeDb({ twistStatus: baseTwistStatus });
    h.dispatch = vi.fn().mockResolvedValue(undefined);
  });

  const run = (msg: FakeMessage) =>
    processUpdates(
      { queue: "updates-development", messages: [msg] } as any,
      {} as any,
      {} as any,
      postHog
    );

  it("retries the message when a write-back dispatch hits a transient DO reset", async () => {
    h.dispatch.mockRejectedValue(doResetError);
    const msg = makeMessage(threadReadBatch);

    await run(msg);

    // Redeliver: the callback never reached the connector, so the queue must
    // hand the whole message back rather than ACK it as done.
    expect(msg.retry).toHaveBeenCalledOnce();
    expect(msg.ack).not.toHaveBeenCalled();
    // Transient blip, retries remain: do NOT page Error Tracking.
    expect(captureException).not.toHaveBeenCalled();
  });

  it("acks and reports once when a transient failure exhausts its retries", async () => {
    h.dispatch.mockRejectedValue(doResetError);
    const msg = makeMessage(threadReadBatch, 3); // final delivery attempt

    await run(msg);

    // No DLQ on the updates queue — report once so a persistent fault doesn't
    // vanish, then ACK so it stops storming.
    expect(msg.ack).toHaveBeenCalledOnce();
    expect(msg.retry).not.toHaveBeenCalled();
    expect(captureException).toHaveBeenCalledTimes(1);
  });

  it("isolates a genuine per-item bug: acks, captures once, does not retry", async () => {
    h.dispatch.mockRejectedValue(
      new Error("Cannot read properties of undefined (reading 'id')")
    );
    const msg = makeMessage(threadReadBatch);

    await run(msg);

    expect(msg.ack).toHaveBeenCalledOnce();
    expect(msg.retry).not.toHaveBeenCalled();
    expect(captureException).toHaveBeenCalledTimes(1);
  });

  it("acks a fully successful batch without retrying or paging", async () => {
    const msg = makeMessage(threadReadBatch);

    await run(msg);

    expect(msg.ack).toHaveBeenCalledOnce();
    expect(msg.retry).not.toHaveBeenCalled();
    expect(captureException).not.toHaveBeenCalled();
  });

  it("isolates a permanent error thrown before dispatch: acks, captures once, no retry", async () => {
    h.currentDb = makeFakeDb({
      twistStatusError: new Error('column "foo" does not exist'),
    });
    const msg = makeMessage(threadReadBatch);

    await run(msg);

    expect(msg.ack).toHaveBeenCalledOnce();
    expect(msg.retry).not.toHaveBeenCalled();
    expect(captureException).toHaveBeenCalledTimes(1);
  });

  // ── Safety gate: never redeliver a message that carries a non-idempotent
  //    reply-send (onNoteCreated). Re-dispatching an already-sent reply
  //    double-sends on connectors without a send guard, so a message with
  //    newNotes / updatedNotes / channelNewNotes must NOT be retried even when
  //    a transient fault occurs.
  it("does NOT retry a message carrying a reply-send, even on a transient fault", async () => {
    h.dispatch.mockRejectedValue(doResetError);
    const msg = makeMessage({ newNotes: [{ id: "n-1", sync_depth: 1 }] as any });

    await run(msg);

    // Would double-send the reply on retry → must ack (drop) instead.
    expect(msg.retry).not.toHaveBeenCalled();
    expect(msg.ack).toHaveBeenCalledOnce();
    // Transient blip: still no capture noise.
    expect(captureException).not.toHaveBeenCalled();
  });

  it("does NOT retry when an idempotent write-back fails but the message also carries an already-sent reply", async () => {
    // newNotes dispatch (Plot + Integrations) succeeds first — the reply is
    // sent — then the threadRead dispatch hits a transient DO reset.
    h.dispatch
      .mockResolvedValueOnce(undefined)
      .mockResolvedValueOnce(undefined)
      .mockRejectedValue(doResetError);
    const msg = makeMessage({
      newNotes: [{ id: "n-1", sync_depth: 1 }] as any,
      threadReads: [{ thread_id: "t-1", user_id: "owner-1" }] as any,
    });

    await run(msg);

    // Retrying would re-run the already-succeeded newNote dispatch → duplicate
    // reply. Safety wins over the dropped thread_read write-back.
    expect(msg.retry).not.toHaveBeenCalled();
    expect(msg.ack).toHaveBeenCalledOnce();
  });
});
