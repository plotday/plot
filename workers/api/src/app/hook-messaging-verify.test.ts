import { describe, it, expect } from "vitest";
import { verifyUnipileSignature } from "./hook-messaging-verify";

async function sign(secret: string, t: string, body: string): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const mac = await crypto.subtle.sign("HMAC", key, enc.encode(`${t}.${body}`));
  return [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

describe("verifyUnipileSignature", () => {
  const secret = "wes_test_secret";
  const body = '{"type":"message.new","payload":{"chat_id":"c1"}}';
  const t = "1710662400";

  it("accepts a valid t=,v0= signature over the timestamp-dot-body payload", async () => {
    const v0 = await sign(secret, t, body);
    expect(await verifyUnipileSignature(`t=${t},v0=${v0}`, body, secret)).toBe(true);
  });

  it("rejects a tampered body (raw-body sensitive)", async () => {
    const v0 = await sign(secret, t, body);
    expect(await verifyUnipileSignature(`t=${t},v0=${v0}`, body + " ", secret)).toBe(false);
  });

  it("rejects the wrong secret", async () => {
    const v0 = await sign(secret, t, body);
    expect(await verifyUnipileSignature(`t=${t},v0=${v0}`, body, "other-secret")).toBe(false);
  });

  it("rejects a missing or malformed header", async () => {
    expect(await verifyUnipileSignature(undefined, body, secret)).toBe(false);
    expect(await verifyUnipileSignature("garbage", body, secret)).toBe(false);
    expect(await verifyUnipileSignature(`t=${t}`, body, secret)).toBe(false);
  });

  it("rejects when no secret is configured", async () => {
    const v0 = await sign(secret, t, body);
    expect(await verifyUnipileSignature(`t=${t},v0=${v0}`, body, "")).toBe(false);
  });
});
