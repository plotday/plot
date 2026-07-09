import { describe, expect, it } from "vitest";

import { isPublicHttpUrl } from "./url-guard";

describe("isPublicHttpUrl", () => {
  it("allows normal public http(s) URLs", () => {
    expect(isPublicHttpUrl("https://example.com/article")).toBe(true);
    expect(isPublicHttpUrl("http://developer.mozilla.org/en-US")).toBe(true);
    expect(isPublicHttpUrl("https://8.8.8.8/x")).toBe(true);
    expect(isPublicHttpUrl("https://1.1.1.1")).toBe(true);
  });

  it("rejects non-http(s) schemes", () => {
    expect(isPublicHttpUrl("ftp://example.com")).toBe(false);
    expect(isPublicHttpUrl("file:///etc/passwd")).toBe(false);
    expect(isPublicHttpUrl("mailto:a@b.com")).toBe(false);
    expect(isPublicHttpUrl("javascript:alert(1)")).toBe(false);
    expect(isPublicHttpUrl("gopher://x")).toBe(false);
  });

  it("rejects malformed / empty input", () => {
    expect(isPublicHttpUrl("not a url")).toBe(false);
    expect(isPublicHttpUrl("")).toBe(false);
    expect(isPublicHttpUrl("https://")).toBe(false);
  });

  it("rejects localhost and internal name suffixes", () => {
    expect(isPublicHttpUrl("http://localhost/x")).toBe(false);
    expect(isPublicHttpUrl("http://localhost:8787/x")).toBe(false);
    expect(isPublicHttpUrl("http://foo.localhost/x")).toBe(false);
    expect(isPublicHttpUrl("http://db.internal/x")).toBe(false);
    expect(isPublicHttpUrl("http://printer.local/x")).toBe(false);
    // Trailing FQDN dot must not bypass the name checks.
    expect(isPublicHttpUrl("http://localhost./x")).toBe(false);
    expect(isPublicHttpUrl("http://localhost../x")).toBe(false);
    expect(isPublicHttpUrl("http://db.internal./x")).toBe(false);
    expect(isPublicHttpUrl("http://printer.local./x")).toBe(false);
  });

  it("rejects private / loopback / link-local / reserved IPv4", () => {
    for (const ip of [
      "http://10.0.0.1/",
      "http://10.255.255.255/",
      "http://127.0.0.1/",
      "http://169.254.169.254/latest/meta-data",
      "http://172.16.0.1/",
      "http://172.31.255.255/",
      "http://192.168.1.1/",
      "http://100.64.0.1/",
      "http://0.0.0.0/",
      "http://224.0.0.1/",
      "http://255.255.255.255/",
    ]) {
      expect(isPublicHttpUrl(ip), ip).toBe(false);
    }
  });

  it("allows public IPv4 just outside the private ranges", () => {
    expect(isPublicHttpUrl("http://172.15.0.1/")).toBe(true);
    expect(isPublicHttpUrl("http://172.32.0.1/")).toBe(true);
    expect(isPublicHttpUrl("http://100.63.0.1/")).toBe(true);
    expect(isPublicHttpUrl("http://11.0.0.1/")).toBe(true);
  });

  it("rejects loopback / link-local / ULA / mapped-private IPv6", () => {
    expect(isPublicHttpUrl("http://[::1]/")).toBe(false);
    expect(isPublicHttpUrl("http://[::]/")).toBe(false);
    expect(isPublicHttpUrl("http://[fe80::1]/")).toBe(false);
    expect(isPublicHttpUrl("http://[fc00::1]/")).toBe(false);
    expect(isPublicHttpUrl("http://[fd12:3456::1]/")).toBe(false);
    expect(isPublicHttpUrl("http://[::ffff:127.0.0.1]/")).toBe(false);
    // IPv4-compatible form (no ffff) must also be decoded and rejected.
    expect(isPublicHttpUrl("http://[::127.0.0.1]/")).toBe(false);
    expect(isPublicHttpUrl("http://[::10.0.0.1]/")).toBe(false);
    expect(isPublicHttpUrl("http://[::169.254.169.254]/latest/meta-data")).toBe(
      false
    );
    expect(isPublicHttpUrl("http://[::192.168.1.1]/")).toBe(false);
    expect(isPublicHttpUrl("http://[::172.16.0.1]/")).toBe(false);
  });

  it("allows public IPv6", () => {
    expect(isPublicHttpUrl("http://[2606:4700:4700::1111]/")).toBe(true);
    expect(isPublicHttpUrl("http://[::ffff:8.8.8.8]/")).toBe(true);
  });
});
