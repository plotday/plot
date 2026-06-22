import { describe, expect, it, vi } from "vitest";
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
  it("captures each dead-lettered message and acks it", async () => {
    const capture = vi.fn();
    const postHog = { captureException: capture } as any;
    const batch = fakeBatch([
      { twistInstanceId: "ti-1", path: ["tasks"], token: "do:tok" },
    ]);
    await handleRunDlq({} as any, batch, postHog);
    expect(capture).toHaveBeenCalledTimes(1);
    expect(batch._acks).toEqual([0]);
  });
});
