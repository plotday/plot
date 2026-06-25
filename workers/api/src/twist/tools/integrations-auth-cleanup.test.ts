import { describe, it, expect } from "vitest";
import { Integrations } from "./integrations";

// Map-backed store stub. onAuth persists `auth_token:<provider>:<actor>` (and
// `enabled_scope_groups:<provider>:<actor>`) BEFORE the account-match / dedup
// guards run. When a guard rejects the just-authed account, those keys must be
// removed — otherwise getIntegrationData (which lists accounts by scanning
// `auth_token:` keys) surfaces the rejected account as a phantom second account
// on a connection that should only ever have one.
function makeHost(initial: Record<string, unknown>) {
  const store = new Map<string, unknown>(Object.entries(initial));
  return {
    store: {
      clear: async (key: string) => {
        store.delete(key);
      },
      get: async (key: string) => store.get(key) ?? null,
      list: async (prefix: string) =>
        [...store.keys()].filter((k) => k.startsWith(prefix)),
    },
    _store: store,
    clearStoredAuthForActor: (Integrations.prototype as any)
      .clearStoredAuthForActor,
  } as any;
}

describe("clearStoredAuthForActor", () => {
  it("removes the rejected actor's auth_token + scope groups, leaving other actors intact", async () => {
    const host = makeHost({
      "auth_token:google:actor-rejected": { access_token: "tok-rejected" },
      "enabled_scope_groups:google:actor-rejected": ["mail"],
      "auth_token:google:actor-bound": { access_token: "tok-bound" },
      "enabled_scope_groups:google:actor-bound": ["mail", "calendar"],
    });

    await host.clearStoredAuthForActor.call(host, "google", "actor-rejected");

    // The rejected account's keys are gone...
    expect(host._store.has("auth_token:google:actor-rejected")).toBe(false);
    expect(host._store.has("enabled_scope_groups:google:actor-rejected")).toBe(
      false
    );
    // ...and the bound account is untouched, so getIntegrationData lists only it.
    expect(host._store.has("auth_token:google:actor-bound")).toBe(true);
    expect(host._store.has("enabled_scope_groups:google:actor-bound")).toBe(
      true
    );
  });

  it("is a no-op when the actor has nothing stored (idempotent)", async () => {
    const host = makeHost({
      "auth_token:google:actor-bound": { access_token: "tok-bound" },
    });

    await host.clearStoredAuthForActor.call(host, "google", "actor-absent");

    expect(host._store.has("auth_token:google:actor-bound")).toBe(true);
    expect(host._store.size).toBe(1);
  });
});
