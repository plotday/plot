import { describe, expect, it, vi } from "vitest";
import { Integrations, withTrelloAppCreds } from "./integrations";
import * as invokeWebhookModule from "../invoke-webhook";

// Hoist the mock so integrations.ts's static import of invokeWebhookCallback
// is intercepted. vi.mock is hoisted above imports by Vitest's transform.
vi.mock("../invoke-webhook", () => ({
  invokeWebhookCallback: vi.fn(),
}));

vi.mock("../../app/sync/notify", () => ({
  notifyUserSyncByEnv: vi.fn(),
}));

// Minimal Durable-Object storage stub: idFromName + get().set()/clear() on the stub.
function makeStorage() {
  const store = new Map<string, string>();
  const stub = {
    get: vi.fn(async (k: string) => store.get(k)),
    set: vi.fn(async (k: string, v: string) => void store.set(k, v)),
    clear: vi.fn(async (_k: string) => undefined),
  };
  return {
    idFromName: vi.fn(() => "auth-id"),
    get: vi.fn(() => stub),
    _stub: stub,
  } as any;
}

function makeEnv() {
  return {
    API_ROOT: "https://api.plot.test",
    AUTH_TRELLO_ID: "trello-key-123",
    AUTH_TRELLO_SECRET: "trello-secret-456",
  } as any;
}

describe("GenerateAuthUrl — Trello token-fragment", () => {
  it("builds the Trello authorize URL with key, response_type=token and state in return_url", async () => {
    const result = await Integrations.GenerateAuthUrl({
      provider: "trello" as any,
      scopes: ["read", "write"],
      redirectUri: "plotday://auth",
      env: makeEnv(),
      storage: makeStorage(),
    });
    expect(result).not.toBeNull();
    const url = new URL(result!.url);
    expect(url.origin + url.pathname).toBe("https://trello.com/1/authorize");
    expect(url.searchParams.get("key")).toBe("trello-key-123");
    expect(url.searchParams.get("response_type")).toBe("token");
    expect(url.searchParams.get("scope")).toBe("read,write");
    expect(url.searchParams.get("expiration")).toBe("never");
    expect(url.searchParams.get("name")).toBe("Plot");
    // state is carried in return_url because Trello does not echo `state`.
    const returnUrl = new URL(url.searchParams.get("return_url")!);
    expect(returnUrl.origin + returnUrl.pathname).toBe("https://api.plot.test/auth/bridge");
    expect(returnUrl.searchParams.get("state")).toBe(result!.state);
    // No PKCE on a token-fragment flow.
    expect(url.searchParams.get("code_challenge")).toBeNull();
  });
});

describe("HandleOauthCallback — Trello token-fragment", () => {
  it("skips the code exchange and invokes onAuth with the relayed token", async () => {
    // Seed AuthState for the state token.
    const storage = makeStorage();
    const state = "state-trello-1";
    const authState = {
      provider: "trello",
      scopes: ["read", "write"],
      callback: { token: "cb-token" } as any,
      clientId: "trello-key-123",
    };
    // superjson is what the runtime uses; a plain JSON string also parses via its fallback.
    storage._stub.set(state, JSON.stringify({ json: authState }));

    // Trello /members/me fetch (called by parseTrelloTokenResponse in onAuth).
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ id: "member-1", username: "k", fullName: "K" }), { status: 200 }),
    );

    const invokeSpy = vi
      .spyOn(invokeWebhookModule, "invokeWebhookCallback")
      .mockResolvedValue(undefined as any);

    const res = await Integrations.HandleOauthCallback(
      storage,
      { state, token: "user-token-abc" },
      makeEnv(),
      { exports: {} } as any,
    );

    expect(res.ok).toBe(true);
    expect(invokeSpy).toHaveBeenCalledTimes(1);
    const payload = invokeSpy.mock.calls[0][3] as any;
    expect(payload.access_token).toBe("user-token-abc");
    expect(payload.provider).toBe("trello");
    expect(payload.key).toBe("trello-key-123");
    expect(payload.scopes).toEqual(["read", "write"]);
  });
});

describe("withTrelloAppCreds — Trello app credential injection", () => {
  it("merges key+secret from env into provider meta for trello", () => {
    expect(
      withTrelloAppCreds("trello" as any, { memberId: "m1" }, makeEnv()),
    ).toMatchObject({
      memberId: "m1",
      key: "trello-key-123",
      secret: "trello-secret-456",
    });
  });

  it("passes through unchanged for non-trello providers", () => {
    expect(withTrelloAppCreds("linear" as any, { x: "1" }, makeEnv())).toEqual({ x: "1" });
  });

  it("returns { key, secret } when meta is undefined for trello", () => {
    expect(
      withTrelloAppCreds("trello" as any, undefined, makeEnv()),
    ).toMatchObject({ key: "trello-key-123", secret: "trello-secret-456" });
  });
});

describe("onAuth — post-auth getChannels dispatch carries Trello app creds", () => {
  // Tests that the authToken passed to the post-auth getChannels dispatch
  // includes Trello app credentials (key+secret) so the connector's getApi
  // can authenticate. Previously the authToken was built without a `provider`
  // field, causing "No Trello credentials" on first connect.

  /** Chainable Kysely stub that returns contextually appropriate rows. */
  function makeMockDb() {
    // Each table returns a minimal row sufficient to satisfy onAuth guards.
    // "contact": user_id needed for connection record.
    // "twist_instance_connection": actor_id === buildActor's return → no mismatch/dedup guards.
    const rows: Record<string, unknown> = {
      contact: { user_id: "user-1" },
      "twist_instance_connection": { actor_id: "actor-1", needs_reauth_at: null },
      twist_instance: { twist_id: "twist-pkg-1", account_label: null },
      // duplicate-check query returns null → no duplicate found
    };
    let currentTable = "";
    const chain: any = {
      selectFrom: (t: string) => { currentTable = t.split(" ")[0]; return chain; },
      innerJoin: () => chain,
      select: () => chain,
      where: () => chain,
      whereRef: () => chain,
      exists: () => chain,
      executeTakeFirst: async () => rows[currentTable] ?? null,
      insertInto: () => chain,
      values: () => chain,
      onConflict: () => chain,
      execute: async () => [],
      updateTable: () => chain,
      set: () => chain,
    };
    return chain;
  }

  function makeOnAuthThis() {
    const storeMap = new Map<string, unknown>();
    return {
      sourceProvider: { provider: "trello" as const },
      env: makeEnv(),
      store: {
        get: vi.fn(async (k: string) => storeMap.get(k) ?? null),
        set: vi.fn(async (k: string, v: unknown) => void storeMap.set(k, v)),
        clear: vi.fn(async () => undefined),
      },
      db: makeMockDb(),
      twistInstanceId: "twist-instance-1",
      _twistId: "twist-1",
      // buildActor: return a stub actor matching the DB mock's actor_id
      buildActor: vi.fn().mockResolvedValue({
        id: "actor-1",
        type: 1 /* ActorType.Contact */,
        name: "K",
      }),
      // buildRecoveryDispatches: no prior reauth, so isRecovery=false and this won't be called
      buildRecoveryDispatches: vi.fn().mockResolvedValue([]),
      // Private helpers referenced in onAuth
      extractEmail: (Integrations.prototype as any).extractEmail,
      flagNeedsReauth: vi.fn().mockResolvedValue(undefined),
    } as any;
  }

  it("dispatch args contain authToken.provider with Trello key and secret", async () => {
    // Trello uses token-fragment flow: parseTrelloTokenResponse fetches /members/me
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({ id: "member-1", username: "k", fullName: "K" }),
        { status: 200 },
      ),
    );

    const self = makeOnAuthThis();
    const tokenInfo = {
      provider: "trello" as any,
      access_token: "user-trello-token",
      scopes: ["read", "write"],
      client_id: "trello-key-123",
    };

    const result = await (Integrations.prototype as any).onAuth.call(self, tokenInfo);

    // onAuth returns a __dispatch array; first entry is getChannels
    expect(result).toBeDefined();
    expect(result.__dispatch).toHaveLength(1);
    const [entry] = result.__dispatch;
    expect(entry.sourceMethod).toBe("getChannels");
    // args[1] is the authToken passed to getChannels
    const authToken = entry.args[1];
    expect(authToken.token).toBe("user-trello-token");
    expect(authToken.provider).toBeDefined();
    expect(authToken.provider.key).toBe("trello-key-123");
    expect(authToken.provider.secret).toBe("trello-secret-456");
  });
});
