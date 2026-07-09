import { describe, it, expect, vi, afterEach } from "vitest";
import { Integrations } from "./integrations";

// removeAuth chains .deleteFrom(...).where().where().where().execute() to drop
// the twist_instance_connection row; a self-returning stub covers the whole
// chain.
function chainableDelete() {
  const chain: Record<string, unknown> = {
    where: () => chain,
    execute: async () => {},
  };
  return chain;
}

// Minimal `this` for Integrations.removeAuth: a map-backed store plus stubs for
// the channel-enumeration / db helpers it touches. The actor owns no channels
// here, so the reassign/disable loop is skipped and we exercise just the
// token-revoke + clear path.
function makeHost(initial: Record<string, unknown>) {
  const store = new Map<string, unknown>(Object.entries(initial));
  return {
    _store: store,
    twistInstanceId: "ti-1",
    sourceProvider: undefined,
    providerConfigs: [],
    env: {},
    store: {
      get: async (key: string) => store.get(key) ?? null,
      set: async (key: string, value: unknown) => {
        store.set(key, value);
      },
      clear: async (key: string) => {
        store.delete(key);
      },
      list: async (prefix: string) =>
        [...store.keys()].filter((k) => k.startsWith(prefix)),
    },
    db: { deleteFrom: () => chainableDelete() },
    getChannelAccess: async () => [],
    flattenChannels: () => [],
    buildSyncContext: async () => ({}),
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    removeAuth: (Integrations.prototype as any).removeAuth,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any;
}

describe("removeAuth — upstream token revocation on disconnect", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("revokes the Slack user token upstream, then clears the local copy", async () => {
    const fetchMock = vi.fn().mockResolvedValue({ ok: true } as Response);
    vi.stubGlobal("fetch", fetchMock);

    const host = makeHost({
      "auth_token:slack:actor-1": { access_token: "xoxp-SECRET" },
    });

    await host.removeAuth.call(host, "slack", "actor-1");

    // Slack's auth.revoke was called with this user's token...
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe("https://slack.com/api/auth.revoke");
    expect(init.method).toBe("POST");
    expect(
      (init.headers as Record<string, string>).Authorization
    ).toBe("Bearer xoxp-SECRET");

    // ...and the local token copy is gone.
    expect(host._store.has("auth_token:slack:actor-1")).toBe(false);
  });

  it("does not attempt an upstream revoke for providers without a revoke endpoint", async () => {
    const fetchMock = vi.fn().mockResolvedValue({ ok: true } as Response);
    vi.stubGlobal("fetch", fetchMock);

    const host = makeHost({
      "auth_token:notion:actor-1": { access_token: "notion-tok" },
    });

    await host.removeAuth.call(host, "notion", "actor-1");

    expect(fetchMock).not.toHaveBeenCalled();
    expect(host._store.has("auth_token:notion:actor-1")).toBe(false);
  });

  it("does not block disconnect when the upstream revoke fails", async () => {
    // A network/HTTP failure on revoke must be swallowed (best-effort) so the
    // local token and connection are still torn down.
    const fetchMock = vi.fn().mockRejectedValue(new Error("network down"));
    vi.stubGlobal("fetch", fetchMock);

    const host = makeHost({
      "auth_token:slack:actor-1": { access_token: "xoxp-SECRET" },
    });

    await expect(
      host.removeAuth.call(host, "slack", "actor-1")
    ).resolves.toBeUndefined();
    expect(host._store.has("auth_token:slack:actor-1")).toBe(false);
  });
});
