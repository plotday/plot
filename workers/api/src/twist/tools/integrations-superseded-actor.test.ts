import { describe, it, expect } from "vitest";
import { Integrations } from "./integrations";

// onAuth's re-bind branch moves a hosted connection from `fromActor` to
// `toActor` (same upstream account, corrected owner contact). It must migrate
// the user's per-connection toggles to the new actor and clear the old actor's
// stored auth — otherwise the leftover auth_token surfaces as a phantom
// duplicate account. migrateSupersededActorAuth is a private method exercised
// here via `.call(host)` against a Map-backed store stub, mirroring the
// clearStoredAuthForActor test.
function makeHost(initial: Record<string, unknown>) {
  const store = new Map<string, unknown>(Object.entries(initial));
  return {
    twistInstanceId: "ti-1",
    store: {
      clear: async (key: string) => {
        store.delete(key);
      },
      get: async (key: string) => store.get(key) ?? null,
      set: async (key: string, value: unknown) => {
        store.set(key, value);
      },
      list: async (prefix: string) =>
        [...store.keys()].filter((k) => k.startsWith(prefix)),
    },
    _store: store,
    clearStoredAuthForActor: (Integrations.prototype as any)
      .clearStoredAuthForActor,
    migrateSupersededActorAuth: (Integrations.prototype as any)
      .migrateSupersededActorAuth,
  } as any;
}

describe("migrateSupersededActorAuth", () => {
  it("clears the old actor's token and migrates toggles the new actor lacks", async () => {
    const host = makeHost({
      "auth_token:linkedin:old": { access_token: "acct-1" },
      "enabled_scope_groups:linkedin:old": ["x"],
      "auto_enable_new_channels:linkedin:old": true,
      "auto_threading_enabled:linkedin:old": true,
      // New actor already has a token (written by onAuth) but no toggles yet.
      "auth_token:linkedin:new": { access_token: "acct-1" },
    });

    await host.migrateSupersededActorAuth.call(host, "linkedin", "old", "new");

    // Old actor fully cleared → only one auth_token remains.
    expect(host._store.has("auth_token:linkedin:old")).toBe(false);
    expect(host._store.has("enabled_scope_groups:linkedin:old")).toBe(false);
    expect(host._store.has("auto_enable_new_channels:linkedin:old")).toBe(false);
    expect(host._store.has("auto_threading_enabled:linkedin:old")).toBe(false);
    expect(host._store.has("auth_token:linkedin:new")).toBe(true);
    // Toggles migrated to the new actor.
    expect(host._store.get("auto_enable_new_channels:linkedin:new")).toBe(true);
    expect(host._store.get("auto_threading_enabled:linkedin:new")).toBe(true);
  });

  it("does not overwrite a toggle the new actor already set (fresh auth wins)", async () => {
    const host = makeHost({
      "auto_enable_new_channels:linkedin:old": true,
      "auto_enable_new_channels:linkedin:new": false,
      "auth_token:linkedin:old": { access_token: "acct-1" },
    });

    await host.migrateSupersededActorAuth.call(host, "linkedin", "old", "new");

    expect(host._store.get("auto_enable_new_channels:linkedin:new")).toBe(false);
    expect(host._store.has("auto_enable_new_channels:linkedin:old")).toBe(false);
  });

  it("is a no-op when from and to actors are identical", async () => {
    const host = makeHost({
      "auth_token:linkedin:same": { access_token: "acct-1" },
    });

    await host.migrateSupersededActorAuth.call(host, "linkedin", "same", "same");

    expect(host._store.has("auth_token:linkedin:same")).toBe(true);
  });
});
