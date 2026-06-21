import { describe, expect, it, vi } from "vitest";

import { SSEStream } from "./sse";

describe("SSEStream heartbeat", () => {
  it("enqueues periodic comment frames while the stream is open", async () => {
    vi.useFakeTimers();
    try {
      const sse = new SSEStream();
      const reader = sse.stream.getReader();
      const decoder = new TextDecoder();

      sse.startHeartbeat(1000);

      await vi.advanceTimersByTimeAsync(1000);
      const first = await reader.read();
      expect(first.done).toBe(false);
      // SSE comment line ("...starting with a colon") — ignored by clients but
      // resets the network read-inactivity timeout (e.g. undici's 300s
      // bodyTimeout) so long silent server operations don't look like a hang.
      expect(decoder.decode(first.value)).toBe(":heartbeat\n\n");

      await vi.advanceTimersByTimeAsync(1000);
      const second = await reader.read();
      expect(decoder.decode(second.value)).toBe(":heartbeat\n\n");
    } finally {
      vi.useRealTimers();
    }
  });

  it("stops the heartbeat once the stream is closed", async () => {
    vi.useFakeTimers();
    try {
      const sse = new SSEStream();
      const reader = sse.stream.getReader();
      const decoder = new TextDecoder();

      sse.startHeartbeat(1000);
      await vi.advanceTimersByTimeAsync(1000);
      const first = await reader.read();
      expect(decoder.decode(first.value)).toBe(":heartbeat\n\n");

      sse.close();

      // After close the interval must be cleared: no more frames are produced
      // and the stream ends cleanly.
      await vi.advanceTimersByTimeAsync(5000);
      const next = await reader.read();
      expect(next.done).toBe(true);
    } finally {
      vi.useRealTimers();
    }
  });
});
