import { describe, it, expect } from "vitest";
import type { ToolBuilder } from "@plotday/twister";
import { Google } from "../src/google";

/**
 * The composite connector's mail send path (`src/mail`) resolves the
 * account's display name from Google's userinfo endpoint to build a
 * `"Name" <email>` From header. That
 * lookup is a plain `fetch`, so the endpoint must be in this connector's own
 * Network allowlist — the outbound proxy 403s anything that isn't, and the
 * send path then silently falls back to a bare address.
 */
function captureNetworkUrls(): string[] | undefined {
  let urls: string[] | undefined;
  const builder = ((_tool: unknown, options?: { urls?: string[] }) => {
    if (options?.urls) urls = options.urls;
    return {} as never;
  }) as unknown as ToolBuilder;

  Google.prototype.build.call({} as Google, builder);
  return urls;
}

describe("Google composite — network allowlist", () => {
  it("permits the userinfo endpoint used to build the outbound From display name", () => {
    expect(captureNetworkUrls()).toContain(
      "https://www.googleapis.com/oauth2/v3/userinfo"
    );
  });

  it("still permits the per-product API hosts", () => {
    const urls = captureNetworkUrls();
    expect(urls).toContain("https://gmail.googleapis.com/gmail/v1/*");
    expect(urls).toContain("https://www.googleapis.com/calendar/*");
    expect(urls).toContain("https://people.googleapis.com/v1/*");
    expect(urls).toContain("https://tasks.googleapis.com/*");
  });
});
