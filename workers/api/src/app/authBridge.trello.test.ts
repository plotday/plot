import { describe, expect, it, vi } from "vitest";
import { Hono } from "hono";
import authBridgeRoutes from "./authBridge";
import { Integrations } from "../twist/tools/integrations";

// Mock the rate-limit middleware before importing authBridge, because
// @hono-rate-limiter/cloudflare uses CJS require('cloudflare:workers') which
// can't be resolved by Vite's alias in the node test environment.
// vi.mock is hoisted by Vitest so this runs before the imports above.
vi.mock("../middleware/rate-limit", () => ({
  authRateLimiter: (_c: any, next: () => Promise<void>) => next(),
}));

function makeEnv(stateValue: object | null) {
  const stub = { get: vi.fn(async () => (stateValue ? JSON.stringify({ json: stateValue }) : null)) };
  return {
    STORAGE: { idFromName: vi.fn(() => "auth"), get: vi.fn(() => stub) },
    API_ROOT: "https://api.plot.test",
    SITE_ROOT: "https://plot.test",
  } as any;
}

function app() {
  const a = new Hono<{ Bindings: any }>();
  a.route("/", authBridgeRoutes);
  return a;
}

describe("auth bridge — Trello fragment capture", () => {
  it("GET renders a capture page that reads location.hash and POSTs the token", async () => {
    const env = makeEnv({ provider: "trello", bridgeUri: "plotday://auth" });
    const res = await app().fetch(
      new Request("https://api.plot.test/auth/bridge?state=st-1"),
      env,
      { waitUntil() {}, passThroughOnException() {} } as any,
    );
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain("location.hash");
    expect(html).toContain("/auth/bridge"); // POST target
    expect(html).toContain("plotday://auth"); // deep-link back target
  });

  it("POST completes the callback with the relayed token", async () => {
    const env = makeEnv({ provider: "trello" });
    const spy = vi
      .spyOn(Integrations, "HandleOauthCallback")
      .mockResolvedValue(new Response(JSON.stringify({ ok: true }), { status: 200 }));
    const res = await app().fetch(
      new Request("https://api.plot.test/auth/bridge", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ state: "st-1", token: "user-token-abc" }),
      }),
      env,
      { waitUntil() {}, passThroughOnException() {} } as any,
    );
    expect(res.status).toBe(200);
    expect(spy).toHaveBeenCalledTimes(1);
    const params = spy.mock.calls[0][1] as Record<string, string>;
    expect(params.state).toBe("st-1");
    expect(params.token).toBe("user-token-abc");
  });

  it("GET capture page escapes </script> in bridgeUri to prevent XSS breakout", async () => {
    const maliciousBridgeUri = "plotday://auth</script><script>alert(1)</script>";
    const env = makeEnv({ provider: "trello", bridgeUri: maliciousBridgeUri });
    const res = await app().fetch(
      new Request("https://api.plot.test/auth/bridge?state=st-1"),
      env,
      { waitUntil() {}, passThroughOnException() {} } as any,
    );
    expect(res.status).toBe(200);
    const html = await res.text();
    // The escaped form must appear (the < was replaced with <)
    expect(html).toContain("\\u003c");
    // There must be exactly ONE </script> — the page's own closing tag
    expect((html.match(/<\/script>/g) || []).length).toBe(1);
  });

  it("POST returns 400 when token is missing from the body", async () => {
    const env = makeEnv({ provider: "trello" });
    const spy = vi.spyOn(Integrations, "HandleOauthCallback");
    const res = await app().fetch(
      new Request("https://api.plot.test/auth/bridge", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ state: "st-1" }),
      }),
      env,
      { waitUntil() {}, passThroughOnException() {} } as any,
    );
    expect(res.status).toBe(400);
    expect(spy).not.toHaveBeenCalled();
  });

  it("POST returns 400 (not 500) when the request body is not valid JSON", async () => {
    const env = makeEnv({ provider: "trello" });
    const spy = vi.spyOn(Integrations, "HandleOauthCallback");
    const res = await app().fetch(
      new Request("https://api.plot.test/auth/bridge", {
        method: "POST",
        headers: { "content-type": "text/plain" },
        body: "not json",
      }),
      env,
      { waitUntil() {}, passThroughOnException() {} } as any,
    );
    expect(res.status).toBe(400);
    expect(spy).not.toHaveBeenCalled();
  });

  it("GET with ?error= does NOT render the capture page for a token-fragment provider", async () => {
    const env = makeEnv({ provider: "trello", bridgeUri: "plotday://auth" });
    const res = await app().fetch(
      new Request("https://api.plot.test/auth/bridge?state=st-1&error=access_denied"),
      env,
      { waitUntil() {}, passThroughOnException() {} } as any,
    );
    const html = await res.text();
    // The capture page injects location.hash reading; must be absent on error
    expect(html).not.toContain("location.hash");
  });
});
