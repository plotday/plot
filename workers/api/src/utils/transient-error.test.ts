import { describe, expect, it } from "vitest";

import { isRateLimitError, isTransientError } from "./transient-error";

describe("isTransientError", () => {
  it("matches the well-defined Cloudflare infra blips", () => {
    expect(isTransientError(new Error("Network connection lost"))).toBe(true);
    expect(isTransientError(new Error("boom (error code: 1019)"))).toBe(true);
    expect(
      isTransientError(
        new Error("Durable Object reset because its code was updated")
      )
    ).toBe(true);
    expect(
      isTransientError(new Error("Queue send failed: Internal Server Error"))
    ).toBe(true);
  });

  it("does NOT match downstream API errors or non-Errors", () => {
    expect(isTransientError(new Error("Gmail API error: 500"))).toBe(false);
    expect(isTransientError("Network connection lost")).toBe(false);
    expect(isTransientError(undefined)).toBe(false);
  });
});

describe("isRateLimitError", () => {
  it("matches Google usageLimits / quota rate-limit signatures", () => {
    // Real GmailApiError 403 body (see PostHog issue 019dbbae-…).
    const quota403 =
      'GmailApiError: Gmail API error: 403 Forbidden - {"error":{"code":403,' +
      '"message":"Quota exceeded for quota metric \'Queries\'","errors":[{' +
      '"reason":"rateLimitExceeded"}],"status":"PERMISSION_DENIED","details":' +
      '[{"reason":"RATE_LIMIT_EXCEEDED"}]}}';
    expect(isRateLimitError(new Error(quota403))).toBe(true);
    expect(
      isRateLimitError(new Error("Error: userRateLimitExceeded"))
    ).toBe(true);
    expect(
      isRateLimitError(new Error("HTTP 429: Too Many Requests"))
    ).toBe(true);
  });

  it("does NOT match unrelated errors, scope 403s, or non-Errors", () => {
    expect(isRateLimitError(new Error("HTTP 404: Not Found"))).toBe(false);
    expect(
      isRateLimitError(new Error("403: ACCESS_TOKEN_SCOPE_INSUFFICIENT"))
    ).toBe(false);
    expect(isRateLimitError(new Error("Cannot read property of undefined"))).toBe(
      false
    );
    expect(isRateLimitError("Quota exceeded")).toBe(false);
  });
});
