import { describe, expect, it } from "vitest";

import {
  findMissingRequiredScopes,
  isInsufficientScopeError,
  parseGrantedScopes,
  resolveRequestedScopes,
} from "./auth-scope";

describe("parseGrantedScopes", () => {
  it("reads the top-level `scope` field by default (Google/Microsoft)", () => {
    const resp = { access_token: "x", scope: "openid email https://cal/events" };
    expect(parseGrantedScopes(resp)).toEqual([
      "openid",
      "email",
      "https://cal/events",
    ]);
  });

  it("returns null when no scope field is present", () => {
    expect(parseGrantedScopes({ access_token: "x" })).toBeNull();
    expect(parseGrantedScopes({ scope: "" })).toBeNull();
    expect(parseGrantedScopes({ scope: "   " })).toBeNull();
  });

  it("uses extractGrantedScopes when provided (Slack user_scope)", () => {
    const resp = {
      access_token: "bot",
      scope: "bot:scope",
      authed_user: { id: "U1", access_token: "user", scope: "users:read chat:write" },
    };
    const config = { extractGrantedScopes: (r: any) => r?.authed_user?.scope };
    expect(parseGrantedScopes(resp, config)).toEqual(["users:read", "chat:write"]);
  });

  it("splits Slack's comma-delimited authed_user.scope", () => {
    // Slack returns the granted user scopes COMMA-separated (not space-
    // separated like RFC 6749's top-level `scope`). Without comma handling
    // the whole string parses as a single bogus scope and every real Slack
    // connect fails the granted-vs-required check.
    const resp = {
      authed_user: {
        scope: "channels:history,channels:read,chat:write,users:read",
      },
    };
    const config = { extractGrantedScopes: (r: any) => r?.authed_user?.scope };
    expect(parseGrantedScopes(resp, config)).toEqual([
      "channels:history",
      "channels:read",
      "chat:write",
      "users:read",
    ]);
  });

  it("falls back to top-level scope when extractGrantedScopes returns undefined", () => {
    const resp = { scope: "a b" };
    const config = { extractGrantedScopes: (r: any) => r?.authed_user?.scope };
    expect(parseGrantedScopes(resp, config)).toEqual(["a", "b"]);
  });

  it("does NOT fall back when extractGrantedScopes returns an empty string", () => {
    // `??` only falls back on null/undefined, not "". This is intentional: for
    // Slack an empty `authed_user.scope` must NOT fall back to the top-level
    // `scope` (which carries bot scopes, not the user grant). An empty granted
    // string means "no user scopes" → return null (skip enforcement).
    const resp = { scope: "bot:scope", authed_user: { scope: "" } };
    const config = { extractGrantedScopes: (r: any) => r?.authed_user?.scope };
    expect(parseGrantedScopes(resp, config)).toBeNull();
  });
});

describe("isInsufficientScopeError", () => {
  const googleBody = JSON.stringify({
    error: {
      code: 403,
      message: "Request had insufficient authentication scopes.",
      status: "PERMISSION_DENIED",
      details: [{ reason: "ACCESS_TOKEN_SCOPE_INSUFFICIENT" }],
    },
  });

  it("matches the marker inside a __TWIST_ERROR__ envelope", () => {
    const envelope =
      "__TWIST_ERROR__" +
      JSON.stringify({
        message: `HTTP 403: ${googleBody}`,
        twistStack: "...",
        operation: "callCallback(refreshChannels)",
        originalError: "Error",
      });
    expect(isInsufficientScopeError(envelope)).toBe(true);
  });

  it("matches a raw (un-enveloped) message carrying the marker", () => {
    expect(isInsufficientScopeError(`HTTP 403: ${googleBody}`)).toBe(true);
  });

  it("matches the insufficientPermissions marker", () => {
    expect(
      isInsufficientScopeError('HTTP 403: {"reason":"insufficientPermissions"}')
    ).toBe(true);
  });

  it("does NOT match a generic 403 or transient error", () => {
    expect(isInsufficientScopeError("HTTP 403: Forbidden")).toBe(false);
    expect(isInsufficientScopeError("HTTP 429: rate limited")).toBe(false);
    expect(isInsufficientScopeError("network timeout")).toBe(false);
  });

  it("does not throw on a malformed __TWIST_ERROR__ envelope", () => {
    expect(isInsufficientScopeError("__TWIST_ERROR__not-json")).toBe(false);
  });
});

describe("resolveRequestedScopes", () => {
  const optional = [
    { id: "contacts", label: "Contacts", scopes: ["s.contacts"], default: true },
    { id: "calendars", label: "Calendars", scopes: ["s.list"], default: true },
  ];

  it("returns required scopes when there are no optional groups", () => {
    expect(resolveRequestedScopes(["s.events"], undefined, undefined)).toEqual([
      "s.events",
    ]);
  });

  it("includes default-on groups when the client sends no selection", () => {
    expect(resolveRequestedScopes(["s.events"], optional, undefined)).toEqual([
      "s.events",
      "s.contacts",
      "s.list",
    ]);
  });

  it("includes only the groups the client explicitly enabled", () => {
    expect(
      resolveRequestedScopes(["s.events"], optional, ["calendars"])
    ).toEqual(["s.events", "s.list"]);
  });

  it("excludes all optional scopes when the client sends an empty selection", () => {
    expect(resolveRequestedScopes(["s.events"], optional, [])).toEqual([
      "s.events",
    ]);
  });

  it("deduplicates overlapping scopes", () => {
    const overlap = [
      { id: "a", label: "A", scopes: ["s.events", "s.a"], default: true },
    ];
    expect(resolveRequestedScopes(["s.events"], overlap, undefined)).toEqual([
      "s.events",
      "s.a",
    ]);
  });
});

describe("findMissingRequiredScopes", () => {
  it("returns required scopes the user did not grant", () => {
    expect(
      findMissingRequiredScopes(["s.events", "s.write"], ["s.events"])
    ).toEqual(["s.write"]);
  });

  it("returns [] when every required scope was granted", () => {
    expect(
      findMissingRequiredScopes(["s.events"], ["s.events", "s.extra"])
    ).toEqual([]);
  });

  it("ignores email/identity scopes the runtime always appends", () => {
    expect(
      findMissingRequiredScopes(["s.events", "openid"], ["s.events"], ["openid"])
    ).toEqual([]);
  });

  it("never flags optional scopes (they are not passed in requiredScopes)", () => {
    expect(findMissingRequiredScopes(["s.events"], ["s.events"])).toEqual([]);
  });
});
