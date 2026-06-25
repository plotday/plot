import { describe, it, expect } from "vitest";
import { boundConnectionsWithoutToken } from "./integrations";

// A connection with a twist_instance_connection row but no stored auth_token —
// bankruptcy-provisioned (never authed) OR token cleared on a permanent refresh
// failure (needs-reauth). getIntegrationData builds `accounts` from auth_token
// keys, so these are missing from the reconnect modal (no accountHint →
// no login_hint). This helper returns the deduped connections that need
// backfilling; the caller enriches each with its OWN stored settings (so a
// needs-reauth account keeps its auto-enable / auto-threading / scope groups).
describe("boundConnectionsWithoutToken", () => {
  it("returns a connection that has no token-based account", () => {
    const out = boundConnectionsWithoutToken([], [
      { provider: "google", actor_id: "actor-bound", email: "kris@example.com" },
    ]);
    expect(out).toEqual([
      { provider: "google", actor_id: "actor-bound", email: "kris@example.com" },
    ]);
  });

  it("skips a connection already represented by a token-based account (no duplicate after reconnect)", () => {
    const existing = [{ provider: "google", actorId: "actor-authed" }];
    const out = boundConnectionsWithoutToken(existing as any, [
      { provider: "google", actor_id: "actor-authed", email: "x@example.com" },
    ]);
    expect(out).toEqual([]);
  });

  it("dedups duplicate connection rows for the same provider+actor", () => {
    const out = boundConnectionsWithoutToken([], [
      { provider: "google", actor_id: "a", email: "a@example.com" },
      { provider: "google", actor_id: "a", email: "a@example.com" },
    ]);
    expect(out).toHaveLength(1);
  });
});
