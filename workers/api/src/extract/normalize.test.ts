import { describe, expect, it } from "vitest";

import { hashUrl, normalizeUrl } from "./normalize";

describe("normalizeUrl", () => {
  it("lowercases the host but preserves path case", () => {
    expect(normalizeUrl("https://Example.COM/Foo/Bar")).toBe(
      "https://example.com/Foo/Bar"
    );
  });

  it("strips the fragment", () => {
    expect(normalizeUrl("https://example.com/article#section-2")).toBe(
      "https://example.com/article"
    );
  });

  it("strips default ports", () => {
    expect(normalizeUrl("https://example.com:443/x")).toBe(
      "https://example.com/x"
    );
    expect(normalizeUrl("http://example.com:80/x")).toBe(
      "http://example.com/x"
    );
  });

  it("preserves non-default ports", () => {
    expect(normalizeUrl("https://example.com:8443/x")).toBe(
      "https://example.com:8443/x"
    );
  });

  it("strips utm_* tracking params (any casing) and known beacons", () => {
    const got = normalizeUrl(
      "https://example.com/x?utm_source=a&UTM_Campaign=b&fbclid=c&gclid=d&id=42&mc_eid=e&mc_cid=f&_ga=g&_gl=h&ref_src=i"
    );
    expect(got).toBe("https://example.com/x?id=42");
  });

  it("preserves non-tracking params in original order", () => {
    expect(
      normalizeUrl("https://example.com/x?z=1&a=2&utm_source=skip&m=3")
    ).toBe("https://example.com/x?z=1&a=2&m=3");
  });

  it("rejects unsupported protocols", () => {
    expect(() => normalizeUrl("ftp://example.com/x")).toThrow();
    expect(() => normalizeUrl("mailto:hi@example.com")).toThrow();
    // eslint-disable-next-line no-script-url -- testing a hostile-looking input
    expect(() => normalizeUrl("javascript:alert(1)")).toThrow();
  });

  it("rejects malformed URLs", () => {
    expect(() => normalizeUrl("not a url")).toThrow();
  });

  it("is idempotent", () => {
    const once = normalizeUrl(
      "HTTPS://Example.com:443/Foo?utm_source=x&id=2#frag"
    );
    const twice = normalizeUrl(once);
    expect(twice).toBe(once);
  });
});

describe("hashUrl", () => {
  it("returns a stable 64-char lowercase hex", async () => {
    const hash = await hashUrl("https://example.com/x");
    expect(hash).toMatch(/^[0-9a-f]{64}$/);
    const again = await hashUrl("https://example.com/x");
    expect(again).toBe(hash);
  });

  it("produces different hashes for different URLs", async () => {
    const a = await hashUrl("https://example.com/x");
    const b = await hashUrl("https://example.com/y");
    expect(a).not.toBe(b);
  });
});
