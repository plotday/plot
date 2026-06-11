import { describe, expect, it } from "vitest";

import {
  isTokenKey,
  openTokenValue,
  sealTokenValue,
} from "./token-encryption";

// 64-char hex (256-bit) test keys
const KEY = "a".repeat(64);
const OTHER_KEY = "b".repeat(64);

describe("isTokenKey", () => {
  it("matches auth_token-prefixed keys only", () => {
    expect(isTokenKey("auth_token:google:abc")).toBe(true);
    expect(isTokenKey("channel_config:google:abc")).toBe(false);
    expect(isTokenKey("")).toBe(false);
  });
});

describe("sealTokenValue / openTokenValue", () => {
  it("round-trips a value through the envelope", async () => {
    const plaintext = JSON.stringify({
      json: { access_token: "secret-token" },
    });
    const sealed = await sealTokenValue(plaintext, KEY);
    expect(sealed).not.toContain("secret-token");
    expect(JSON.parse(sealed).__enc).toBe(1);
    const opened = await openTokenValue(sealed, KEY);
    expect(opened).toBe(plaintext);
  });

  it("passes plaintext through unchanged when no key is configured", async () => {
    const plaintext = '{"json":{"access_token":"legacy"}}';
    expect(await sealTokenValue(plaintext, undefined)).toBe(plaintext);
  });

  it("returns legacy (non-envelope) values unchanged on open", async () => {
    const legacy = '{"json":{"access_token":"legacy"}}';
    expect(await openTokenValue(legacy, KEY)).toBe(legacy);
    expect(await openTokenValue(legacy, undefined)).toBe(legacy);
  });

  it("returns null when an envelope can't be opened", async () => {
    const sealed = await sealTokenValue("secret", KEY);
    // Envelope but no key configured
    expect(await openTokenValue(sealed, undefined)).toBeNull();
    // Envelope but wrong key
    expect(await openTokenValue(sealed, OTHER_KEY)).toBeNull();
  });
});
