import { describe, expect, it } from "vitest";

import {
  isAuthError,
  isRateLimitError,
  isTransientDoResetError,
  isTransientError,
  transientErrorReason,
} from "./transient-error";

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

  it("matches a Cloudflare isolate OOM (self-resolves on retry)", () => {
    // Verbatim Workers runtime string when an isolate exceeds its 128 MB
    // ceiling; one OOM rejects every in-flight promise at once (PostHog issue
    // 019ed581: 107 captures / 62 phantom distinct_ids from one 2026-06-21
    // incident). Classified transient so both queue consumers AND
    // handleTwistOperation retry it instead of paging Error Tracking.
    expect(
      isTransientError(new Error("Worker exceeded memory limit."))
    ).toBe(true);
    // PostHog also ingests the variant prefixed with the Error name.
    expect(
      isTransientError(new Error("Error: Worker exceeded memory limit."))
    ).toBe(true);
  });

  it("does NOT match downstream API errors or non-Errors", () => {
    expect(isTransientError(new Error("Gmail API error: 500"))).toBe(false);
    expect(isTransientError("Network connection lost")).toBe(false);
    expect(isTransientError(undefined)).toBe(false);
    // A connector log mentioning memory but not the runtime kill must not trip.
    expect(
      isTransientError(new Error("loaded 5000 messages into memory"))
    ).toBe(false);
  });
});

describe("isTransientDoResetError", () => {
  it("matches the verbatim Cloudflare DO-reset platform strings", () => {
    // Exact string the Workers runtime emits when a Durable Object storage
    // operation overruns its internal timeout and the platform resets the
    // object (PostHog issue 019ebd3b: 7 captures from PushNotify.alarm). The
    // DO is reset and the next notify() schedules a fresh alarm, so it is
    // platform noise — never paged.
    expect(
      isTransientDoResetError(
        new Error(
          "Durable Object storage operation exceeded timeout which caused object to be reset."
        )
      )
    ).toBe(true);
    // Generic platform fault wrapper.
    expect(
      isTransientDoResetError(new Error("internal error; reference = abc123"))
    ).toBe(true);
    // Storage failed to initialize and the platform reset the object. Both
    // "while starting up" (issue 019f277a) and "in" phrasings are matched on
    // the stable signature.
    expect(
      isTransientDoResetError(
        new Error(
          "Internal error while starting up Durable Object storage caused " +
            "object to be reset; reference = q1jnt2ahu9rjefmqe6npchv9"
        )
      )
    ).toBe(true);
    expect(
      isTransientDoResetError(
        new Error(
          "Internal error in Durable Object storage caused object to be " +
            "reset; reference = 26ou2mt86hahckspbj7bpcar"
        )
      )
    ).toBe(true);
    // DO-to-DO fetch dropped mid-flight.
    expect(
      isTransientDoResetError(new Error("Network connection lost"))
    ).toBe(true);
  });

  it("does NOT match real bugs or non-Errors", () => {
    expect(
      isTransientDoResetError(new Error("Cannot read properties of undefined"))
    ).toBe(false);
    expect(isTransientDoResetError(new Error("Gmail API error: 500"))).toBe(
      false
    );
    expect(
      isTransientDoResetError(
        "Durable Object storage operation exceeded timeout"
      )
    ).toBe(false);
    expect(isTransientDoResetError(undefined)).toBe(false);
  });
});

describe("transientErrorReason", () => {
  it("labels each suppressed transient push-DO failure mode", () => {
    expect(
      transientErrorReason(
        new Error(
          "Durable Object storage operation exceeded timeout which caused object to be reset."
        )
      )
    ).toBe("do_storage_timeout");
    expect(
      transientErrorReason(new Error("internal error; reference = abc123"))
    ).toBe("platform_internal");
    expect(
      transientErrorReason(
        new Error(
          "Internal error while starting up Durable Object storage caused " +
            "object to be reset; reference = q1jnt2ahu9rjefmqe6npchv9"
        )
      )
    ).toBe("do_storage_reset");
    expect(transientErrorReason(new Error("Network connection lost"))).toBe(
      "network_lost"
    );
    // pg / Hyperdrive drops (mirrors isTransientDbError, case-insensitive).
    expect(
      transientErrorReason(new Error("Connection terminated unexpectedly"))
    ).toBe("db_drop");
    expect(
      transientErrorReason(
        new Error("Timed out while waiting for an open slot in the pool.")
      )
    ).toBe("db_drop");
  });

  it("maps unrecognized errors and non-Errors to 'other'", () => {
    expect(
      transientErrorReason(new Error("Cannot read properties of undefined"))
    ).toBe("other");
    expect(transientErrorReason(undefined)).toBe("other");
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

describe("isAuthError", () => {
  it("matches terminal credential-rejection signatures", () => {
    // Real Gmail 401 body (PostHog issue 019dbbae).
    const gmail401 =
      'GmailApiError: Gmail API error: 401 Unauthorized - {"error":{"code":401,' +
      '"message":"Request had invalid authentication credentials.","errors":[{' +
      '"reason":"authError"}],"status":"UNAUTHENTICATED"}}';
    expect(isAuthError(new Error(gmail401))).toBe(true);
    expect(isAuthError(new Error("Error: Invalid Credentials"))).toBe(true);
    expect(isAuthError(new Error("token refresh failed: invalid_grant"))).toBe(
      true
    );
    expect(
      isAuthError(new Error("InvalidAuthenticationToken: token expired"))
    ).toBe(true);
    // Google-Calendar connector 401 wrapper.
    expect(
      isAuthError(new Error("Authentication failed - token may be expired"))
    ).toBe(true);
    // Unipile messaging tool: the stored account credential is gone, so the
    // user must reconnect. Terminal (won't self-resolve on retry) — must be
    // ACK'd, not retry-stormed. See assertAccount in twist/tools/unipile.
    expect(
      isAuthError(
        new Error(
          "linkedin channel WFhho1nhRX2h_MVBvedTlQ has no stored credentials — reconnect"
        )
      )
    ).toBe(true);
  });

  it("does NOT match rate-limits, 404s, bare 401, or non-Errors", () => {
    expect(isAuthError(new Error("HTTP 404: Not Found"))).toBe(false);
    expect(isAuthError(new Error("Gmail API error: 403 rateLimitExceeded"))).toBe(
      false
    );
    // A bare "401" inside an unrelated payload must not trip the classifier.
    expect(isAuthError(new Error("synced 401 messages"))).toBe(false);
    expect(isAuthError("Invalid Credentials")).toBe(false);
  });
});
