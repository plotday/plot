import { afterEach, describe, expect, it, vi } from "vitest";

import { GmailApi, GmailApiError, isGmailRateLimitError } from "./gmail-api";

/**
 * Rate-limit / transient retry for {@link GmailApi.call}. Gmail write-backs
 * (star / read via modifyThread) had NO backoff: a single per-user-per-minute
 * quota 403 (`rateLimitExceeded`) threw straight through and the change was
 * dropped (PostHog 019ed581). `call()` now absorbs brief blips in-process and
 * throws on sustained ones so the caller can defer.
 */
describe("GmailApi.call — rate-limit / transient retry", () => {
  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  it("retries a 429 then succeeds", async () => {
    vi.useFakeTimers();
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(
        new Response("rate", { status: 429, statusText: "Too Many Requests" })
      )
      .mockResolvedValueOnce(
        new Response(JSON.stringify({ ok: true }), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        })
      );
    vi.stubGlobal("fetch", fetchMock);

    const p = new GmailApi("tok").call("/profile");
    await vi.runAllTimersAsync();
    await expect(p).resolves.toEqual({ ok: true });
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("retries a 403 rateLimitExceeded then succeeds", async () => {
    vi.useFakeTimers();
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            error: { errors: [{ reason: "rateLimitExceeded" }], message: "Quota exceeded" },
          }),
          { status: 403, statusText: "Forbidden" }
        )
      )
      .mockResolvedValueOnce(new Response(null, { status: 204 }));
    vi.stubGlobal("fetch", fetchMock);

    const p = new GmailApi("tok").modifyThread("t1", ["STARRED"]);
    await vi.runAllTimersAsync();
    await expect(p).resolves.toBeUndefined();
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("retries a 5xx then succeeds", async () => {
    vi.useFakeTimers();
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(
        new Response("oops", { status: 503, statusText: "Service Unavailable" })
      )
      .mockResolvedValueOnce(
        new Response(JSON.stringify({ ok: true }), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        })
      );
    vi.stubGlobal("fetch", fetchMock);

    const p = new GmailApi("tok").call("/profile");
    await vi.runAllTimersAsync();
    await expect(p).resolves.toEqual({ ok: true });
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("does NOT retry a 403 that is not a rate-limit (permission error)", async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ error: { message: "Insufficient Permission" } }), {
        status: 403,
        statusText: "Forbidden",
      })
    );
    vi.stubGlobal("fetch", fetchMock);

    await expect(new GmailApi("tok").call("/profile")).rejects.toMatchObject({
      name: "GmailApiError",
      status: 403,
    });
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("does NOT retry a 404", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValue(new Response("missing", { status: 404, statusText: "Not Found" }));
    vi.stubGlobal("fetch", fetchMock);

    await expect(new GmailApi("tok").call("/threads/x")).rejects.toMatchObject({
      status: 404,
    });
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("does NOT retry in-process when Retry-After exceeds the cap (defers instead)", async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response("rate", { status: 429, headers: { "Retry-After": "120" } })
    );
    vi.stubGlobal("fetch", fetchMock);

    await expect(new GmailApi("tok").call("/profile")).rejects.toMatchObject({
      status: 429,
    });
    // A 2-minute wait belongs in the deferred drain, not an in-flight isolate.
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("throws after exhausting retries on a persistent 429", async () => {
    vi.useFakeTimers();
    // Fresh Response per call — a Response body can only be read once.
    const fetchMock = vi
      .fn()
      .mockImplementation(
        async () =>
          new Response("rate", { status: 429, statusText: "Too Many Requests" })
      );
    vi.stubGlobal("fetch", fetchMock);

    const p = new GmailApi("tok").call("/profile");
    p.catch(() => {}); // avoid unhandled-rejection noise while timers advance
    await vi.runAllTimersAsync();
    await expect(p).rejects.toMatchObject({ status: 429 });
    expect(fetchMock).toHaveBeenCalledTimes(3); // 1 initial + 2 retries
  });
});

describe("isGmailRateLimitError", () => {
  it("is true for HTTP 429", () => {
    expect(isGmailRateLimitError(new GmailApiError(429, "Too Many Requests", ""))).toBe(true);
  });
  it("is true for a 403 rateLimitExceeded body", () => {
    expect(
      isGmailRateLimitError(new GmailApiError(403, "Forbidden", '...reason: "rateLimitExceeded"...'))
    ).toBe(true);
  });
  it("is true for a 403 Quota exceeded body", () => {
    expect(
      isGmailRateLimitError(new GmailApiError(403, "Forbidden", "Quota exceeded for quota metric"))
    ).toBe(true);
  });
  it("is false for a 403 permission error", () => {
    expect(
      isGmailRateLimitError(new GmailApiError(403, "Forbidden", "Insufficient Permission"))
    ).toBe(false);
  });
  it("is false for a 404", () => {
    expect(isGmailRateLimitError(new GmailApiError(404, "Not Found", ""))).toBe(false);
  });
  it("is false for a non-GmailApiError that merely mentions the marker", () => {
    expect(isGmailRateLimitError(new Error("rateLimitExceeded"))).toBe(false);
  });
});
