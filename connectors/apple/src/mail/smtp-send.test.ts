import { describe, expect, it } from "vitest";
import type { SmtpSendResult } from "@plotday/twister/tools/smtp";

import { classifySmtpError, sendWithRetry } from "./smtp-send";

const noSleep = async () => {};

describe("classifySmtpError", () => {
  it("classifies a 5xx recipient rejection as permanent/rejected", () => {
    const e = classifySmtpError(new Error("RCPT TO failed: 550 5.1.1 user unknown"));
    expect(e.class).toBe("permanent");
    expect(e.code).toBe("rejected");
  });
  it("classifies auth failure as auth", () => {
    const e = classifySmtpError(new Error("SMTP authentication failed: 535 5.7.8 bad login"));
    expect(e.class).toBe("auth");
    expect(e.code).toBe("auth");
  });
  it("classifies a 4xx as transient/rate_limited", () => {
    const e = classifySmtpError(new Error("451 4.7.1 try later"));
    expect(e.class).toBe("transient");
    expect(e.code).toBe("rate_limited");
  });
  it("classifies a connection/network error as transient/connection_error", () => {
    const closed = classifySmtpError(new Error("SMTP connection closed unexpectedly"));
    expect(closed.class).toBe("transient");
    expect(closed.code).toBe("connection_error");
    expect(classifySmtpError(new Error("network unreachable")).code).toBe("connection_error");
  });
  it("classifies an unrecognised error as permanent send_failed (not a page)", () => {
    const e = classifySmtpError(new Error("something weird"));
    expect(e.class).toBe("permanent");
    expect(e.code).toBe("send_failed");
  });
});

describe("sendWithRetry", () => {
  const ok: SmtpSendResult = { messageId: "<x@plot.day>", accepted: ["a@b.com"], rejected: [] };

  it("returns ok on first success", async () => {
    const out = await sendWithRetry(async () => ok, noSleep);
    expect(out).toEqual({ ok: true, result: ok });
  });
  it("retries transient failures then succeeds", async () => {
    let n = 0;
    const out = await sendWithRetry(async () => {
      if (n++ < 1) throw new Error("451 try later");
      return ok;
    }, noSleep);
    expect(out.ok).toBe(true);
    expect(n).toBe(2);
  });
  it("does not retry a permanent failure", async () => {
    let n = 0;
    const out = await sendWithRetry(async () => {
      n++;
      throw new Error("550 rejected");
    }, noSleep);
    expect(out.ok).toBe(false);
    expect(n).toBe(1);
    if (!out.ok) expect(out.error.code).toBe("rejected");
  });
  it("gives up after exhausting transient retries", async () => {
    let n = 0;
    const out = await sendWithRetry(async () => {
      n++;
      throw new Error("451 try later");
    }, noSleep);
    expect(out.ok).toBe(false);
    expect(n).toBe(3);
  });
});
