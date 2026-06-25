import { describe, expect, it } from "vitest";
import { handleRunDlq } from "./run-dlq";

function fakeBatch(bodies: any[]) {
  const acks: number[] = [];
  return {
    queue: "run-dlq-test",
    messages: bodies.map((body, i) => ({
      body,
      attempts: 4,
      ack: () => acks.push(i),
      retry: () => {},
    })),
    _acks: acks,
  } as any;
}

describe("handleRunDlq", () => {
  // Terminal observability consumer: it must ack every dead-lettered message
  // (so it never loops) and must NOT page PostHog Error Tracking. The drop is
  // recorded via a structured logger.error instead — see run-dlq.ts for why a
  // captureException here was redundant (real bugs are already captured
  // per-attempt by processQueue) or expected (rate-limit/transient exhaustion).
  // The handler no longer accepts a PostHog client, so "does not page" is
  // enforced by the signature; this asserts the terminal ack behaviour, incl.
  // the empty-path case (a connector's own recurring poll) that produced the
  // uninformative `RUN_QUEUE dead-letter: ` captures in PostHog 019ed581.
  it("acks every dead-lettered message", async () => {
    const batch = fakeBatch([
      { twistInstanceId: "ti-1", path: ["tasks"], token: "do:tok" },
      { twistInstanceId: "ti-2", path: [], token: "do:tok2" },
    ]);
    await handleRunDlq(batch);
    expect(batch._acks).toEqual([0, 1]);
  });
});
