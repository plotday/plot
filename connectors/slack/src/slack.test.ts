import { describe, expect, it, vi } from "vitest";
import { AuthProvider, type Authorization } from "@plotday/twister/tools/integrations";
import { Slack } from "./slack";

/**
 * In-memory store backing `this.get` / `this.set` (which delegate to
 * `this.tools.store`). `list` filters keys by prefix the way the real store
 * tool does.
 */
function makeStore(initial: Record<string, unknown> = {}) {
  const map = new Map<string, unknown>(Object.entries(initial));
  return {
    map,
    get: vi.fn(async (key: string) => (map.has(key) ? map.get(key) : null)),
    set: vi.fn(async (key: string, value: unknown) => {
      map.set(key, value);
    }),
    clear: vi.fn(async (key: string) => {
      map.delete(key);
    }),
    list: vi.fn(async (prefix: string) =>
      [...map.keys()].filter((k) => k.startsWith(prefix))
    ),
  };
}

function makeSlack(opts: {
  store: ReturnType<typeof makeStore>;
  integrationsGet: ReturnType<typeof vi.fn>;
  createWebhook: ReturnType<typeof vi.fn>;
}): Slack {
  const tools = {
    store: opts.store,
    integrations: { get: opts.integrationsGet },
    network: { createWebhook: opts.createWebhook },
    files: {},
  };
  const toolShed = { getTools: () => tools };
  return new Slack("twist-instance-1" as never, toolShed as never);
}

describe("saveStarredThread", () => {
  it("saves the link with todo:true and no status", async () => {
    const store = makeStore({ auth_actor_id: "actor-1" });
    const saveLink = vi.fn().mockResolvedValue("thread-1");
    const tools = {
      store,
      integrations: { get: vi.fn(), saveLink },
      network: { createWebhook: vi.fn() },
      files: {},
    };
    const slack = new Slack(
      "twist-instance-1" as never,
      { getTools: () => tools } as never
    );

    const api = {
      getThread: vi.fn().mockResolvedValue([
        { ts: "111.000", thread_ts: "111.000", user: "U1", text: "hello", reactions: [] },
      ]),
      getUser: vi.fn().mockResolvedValue(null),
    };

    await (slack as unknown as {
      saveStarredThread: (a: unknown, c: string, t: string) => Promise<void>;
    }).saveStarredThread(api, "C123", "111.000");

    expect(saveLink).toHaveBeenCalledTimes(1);
    const saved = saveLink.mock.calls[0][0];
    expect(saved.todo).toBe(true);
    expect(saved.status).toBeUndefined();
  });
});

describe("setupChannelWebhook", () => {
  const channelId = "C123";
  const auth: Authorization = {
    provider: AuthProvider.Slack,
    actor: { id: "actor-1" },
  } as Authorization;

  it("does not register a webhook when the integration token has been removed", async () => {
    // The connector's stored "auth" Authorization survives token removal
    // (it's written once in activate() and never cleared), so it is present
    // even though the underlying OAuth token is gone. Registering anyway makes
    // createSlackWebhook throw "No integration found for authorization", which
    // then retries forever on the webhook queue.
    const store = makeStore({ auth });
    const createWebhook = vi.fn().mockResolvedValue("slack://team/tok");
    const integrationsGet = vi.fn().mockResolvedValue(null); // token cleared
    const slack = makeSlack({ store, integrationsGet, createWebhook });

    await expect(slack.setupChannelWebhook(channelId)).resolves.toBeUndefined();

    expect(integrationsGet).toHaveBeenCalledWith(channelId);
    expect(createWebhook).not.toHaveBeenCalled();
    expect(store.map.has(`channel_webhook_${channelId}`)).toBe(false);
  });

  it("registers a webhook and persists state when a usable token exists", async () => {
    const store = makeStore({ auth });
    const createWebhook = vi.fn().mockResolvedValue("slack://team/tok");
    const integrationsGet = vi.fn().mockResolvedValue({ token: "xoxp-test" });
    const slack = makeSlack({ store, integrationsGet, createWebhook });

    await slack.setupChannelWebhook(channelId);

    expect(createWebhook).toHaveBeenCalledTimes(1);
    expect(store.map.get(`channel_webhook_${channelId}`)).toMatchObject({
      url: "slack://team/tok",
      channelId,
    });
  });

  it("does nothing when there is no stored Authorization at all", async () => {
    const store = makeStore({});
    const createWebhook = vi.fn().mockResolvedValue("slack://team/tok");
    const integrationsGet = vi.fn().mockResolvedValue({ token: "xoxp-test" });
    const slack = makeSlack({ store, integrationsGet, createWebhook });

    await slack.setupChannelWebhook(channelId);

    expect(createWebhook).not.toHaveBeenCalled();
  });
});

describe("syncCustomEmoji", () => {
  /** Build a Slack with the tool set needed by syncCustomEmoji. */
  function makeEmojiSlack(opts: {
    store: ReturnType<typeof makeStore>;
    integrationsGet: ReturnType<typeof vi.fn>;
    saveCustomEmoji: ReturnType<typeof vi.fn>;
  }) {
    const create = vi.fn(async () => ({ token: "cb" }) as never);
    const runTask = vi.fn(async () => "task-token");
    const tools = {
      store: opts.store,
      integrations: {
        get: opts.integrationsGet,
        saveCustomEmoji: opts.saveCustomEmoji,
      },
      network: { createWebhook: vi.fn() },
      files: {},
      callbacks: { create },
      tasks: { runTask },
    };
    const slack = new Slack(
      "twist-instance-1" as never,
      { getTools: () => tools } as never
    );
    return { slack, create, runTask };
  }

  /** Mock global.fetch to answer one `emoji.list` call with `emoji`. */
  function mockEmojiListFetch(emoji: Record<string, string>) {
    return vi.fn(async () =>
      ({
        ok: true,
        status: 200,
        headers: { get: () => null },
        json: async () => ({ ok: true, emoji }),
      }) as never
    );
  }

  it("saves refs with alias resolution and caches the name set", async () => {
    const store = makeStore({});
    const integrationsGet = vi.fn().mockResolvedValue({
      token: "xoxp-test",
      scopes: ["emoji:read"],
      provider: { team_id: "T0" },
    });
    const saveCustomEmoji = vi.fn().mockResolvedValue(undefined);
    const { slack } = makeEmojiSlack({ store, integrationsGet, saveCustomEmoji });

    const fetchMock = mockEmojiListFetch({
      party_parrot: "https://e/pp.gif",
      pp2: "alias:party_parrot",
    });
    vi.stubGlobal("fetch", fetchMock);
    try {
      await (slack as unknown as {
        syncCustomEmoji: (c: string) => Promise<void>;
      }).syncCustomEmoji("C1");
    } finally {
      vi.unstubAllGlobals();
    }

    expect(saveCustomEmoji).toHaveBeenCalledTimes(1);
    const saved = saveCustomEmoji.mock.calls[0][0] as Array<{
      id: string;
      imageUrl: string | null;
      aliasOf: string | null;
      name: string;
      workspace: string;
      provider: string;
    }>;
    const parrot = saved.find((e) => e.id === "slack:T0/party_parrot")!;
    expect(parrot).toBeDefined();
    expect(parrot.imageUrl).toBe("https://e/pp.gif");
    expect(parrot.aliasOf).toBeNull();
    expect(parrot.provider).toBe("slack");
    expect(parrot.workspace).toBe("T0");
    const alias = saved.find((e) => e.id === "slack:T0/pp2")!;
    expect(alias).toBeDefined();
    expect(alias.imageUrl).toBeNull();
    expect(alias.aliasOf).toBe("slack:T0/party_parrot");

    // Name set cached for the inbound transform.
    expect(store.map.get("custom_emoji_T0")).toEqual(["party_parrot", "pp2"]);
  });

  it("no-ops when emoji:read is not granted", async () => {
    const store = makeStore({});
    const integrationsGet = vi.fn().mockResolvedValue({
      token: "xoxp-test",
      scopes: ["channels:history"], // no emoji:read
      provider: { team_id: "T0" },
    });
    const saveCustomEmoji = vi.fn().mockResolvedValue(undefined);
    const { slack } = makeEmojiSlack({ store, integrationsGet, saveCustomEmoji });

    const fetchMock = mockEmojiListFetch({ party_parrot: "https://e/pp.gif" });
    vi.stubGlobal("fetch", fetchMock);
    try {
      await (slack as unknown as {
        syncCustomEmoji: (c: string) => Promise<void>;
      }).syncCustomEmoji("C1");
    } finally {
      vi.unstubAllGlobals();
    }

    expect(saveCustomEmoji).not.toHaveBeenCalled();
    expect(fetchMock).not.toHaveBeenCalled();
    expect(store.map.has("custom_emoji_T0")).toBe(false);
  });
});
