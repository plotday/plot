import { describe, expect, it } from "vitest";
import { GmailApiError } from "./gmail-api";
import { classifySendError } from "./gmail-send-errors";

function apiError(status: number, body: string): GmailApiError {
  return new GmailApiError(status, "Error", body);
}

describe("classifySendError", () => {
  it("treats a non-GmailApiError (network/fetch failure) as transient", () => {
    expect(classifySendError(new TypeError("Network connection lost")).class).toBe(
      "transient"
    );
    expect(classifySendError(new Error("boom")).class).toBe("transient");
  });

  it("classifies 429 as transient rate limit", () => {
    const c = classifySendError(apiError(429, "Too Many Requests"));
    expect(c.class).toBe("transient");
    expect(c.code).toBe("rate_limited");
  });

  it("classifies 5xx as transient", () => {
    expect(classifySendError(apiError(500, "boom")).class).toBe("transient");
    expect(classifySendError(apiError(503, "unavailable")).class).toBe("transient");
  });

  it("splits 403 by body: rate-limit marker is transient, otherwise auth", () => {
    expect(
      classifySendError(apiError(403, '{"error":{"errors":[{"reason":"rateLimitExceeded"}]}}'))
        .class
    ).toBe("transient");
    expect(
      classifySendError(apiError(403, '{"error":{"errors":[{"reason":"userRateLimitExceeded"}]}}'))
        .class
    ).toBe("transient");
    expect(classifySendError(apiError(403, "insufficientPermissions")).class).toBe(
      "auth"
    );
  });

  it("classifies 401 as auth", () => {
    expect(classifySendError(apiError(401, "Invalid Credentials")).class).toBe("auth");
  });

  it("classifies 413 / too-large as permanent", () => {
    expect(classifySendError(apiError(413, "Payload Too Large")).class).toBe("permanent");
    const tooLarge = classifySendError(apiError(400, "messageTooLarge"));
    expect(tooLarge.class).toBe("permanent");
    expect(tooLarge.code).toBe("too_large");
  });

  it("classifies a rejected recipient (400) as permanent", () => {
    const c = classifySendError(apiError(400, "Invalid To header: bad@@example"));
    expect(c.class).toBe("permanent");
    expect(c.code).toBe("rejected");
  });

  it("classifies a generic 400 (and other 4xx) as permanent rejection", () => {
    expect(classifySendError(apiError(400, "Bad Request")).class).toBe("permanent");
    expect(classifySendError(apiError(418, "I'm a teapot")).class).toBe("permanent");
  });

  it("returns unknown for an unexpected non-4xx/5xx status so the caller can rethrow", () => {
    expect(classifySendError(apiError(302, "Found")).class).toBe("unknown");
  });

  it("always provides a stable code", () => {
    for (const status of [400, 401, 403, 413, 429, 500]) {
      expect(typeof classifySendError(apiError(status, "x")).code).toBe("string");
    }
  });
});
