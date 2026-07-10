import { describe, expect, it, vi } from "vitest";
import { AuthProvider, type Authorization } from "@plotday/twister/tools/integrations";
import { Slack } from "./slack";
import {
  extractSlackMessageReactions,
  type SlackMessage,
} from "./slack-api";

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
    // The platform now suppresses the onThreadToDo echo via write-source
    // provenance stamped by saveLink's todo path — the connector no longer
    // writes a skip_todo_writeback echo guard.
    expect(store.set).not.toHaveBeenCalledWith(
      expect.stringContaining("skip_todo_writeback"),
      expect.anything()
    );
  });
});

describe("onThreadToDo — no skip_todo_writeback echo guard", () => {
  it("writes back to Slack even when a stale skip_todo_writeback key is present", async () => {
    const store = makeStore({
      // A leftover key from a pre-cleanup deploy must NOT short-circuit the
      // write-back — the guard has been removed.
      "skip_todo_writeback:C123:111.000": true,
    });
    const slack = makeSlack({
      store,
      integrationsGet: vi.fn(),
      createWebhook: vi.fn(),
    });
    const api = { addStar: vi.fn(), removeStar: vi.fn() };
    vi.spyOn(
      slack as unknown as { getApi: (c: string) => Promise<unknown> },
      "getApi"
    ).mockResolvedValue(api);

    const thread = { meta: { channelId: "C123", threadTs: "111.000" } };
    await slack.onThreadToDo(thread as never, {} as never, true, {});

    expect(api.addStar).toHaveBeenCalledWith("C123", "111.000");
    expect(store.clear).not.toHaveBeenCalledWith(
      "skip_todo_writeback:C123:111.000"
    );
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

describe("onChannelEnabled — initial sync completion signal", () => {
  const channel = { id: "C123", title: "general" };

  function makeOnChannelEnabledSlack() {
    const store = makeStore({});
    const create = vi.fn(async () => ({ token: "cb" }) as never);
    const runTask = vi.fn(async () => "task-token");
    const channelSyncCompleted = vi.fn().mockResolvedValue(undefined);
    const tools = {
      store,
      integrations: {
        get: vi.fn(),
        channelSyncCompleted,
      },
      network: { createWebhook: vi.fn() },
      files: {},
      callbacks: { create },
      tasks: { runTask, scheduleRecurring: vi.fn(async () => {}) },
    };
    const slack = new Slack(
      "twist-instance-1" as never,
      { getTools: () => tools } as never
    );
    return { slack, channelSyncCompleted, store };
  }

  it("calls channelSyncCompleted for the enabled channel, not gated on backfill", async () => {
    const { slack, channelSyncCompleted } = makeOnChannelEnabledSlack();

    await slack.onChannelEnabled(channel as never, undefined);

    expect(channelSyncCompleted).toHaveBeenCalledWith("C123");
  });

  it("still calls channelSyncCompleted when observeOnly is true", async () => {
    const { slack, channelSyncCompleted } = makeOnChannelEnabledSlack();

    await slack.onChannelEnabled(channel as never, { observeOnly: true } as never);

    expect(channelSyncCompleted).toHaveBeenCalledWith("C123");
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
      tasks: { runTask, scheduleRecurring: vi.fn(async () => {}) },
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

    // Non-alias rows are saved before alias rows so alias_of always
    // references an already-inserted row (see next test for why).
    expect(saveCustomEmoji).toHaveBeenCalledTimes(2);
    const saved = [
      ...(saveCustomEmoji.mock.calls[0][0] as Array<{
        id: string;
        imageUrl: string | null;
        aliasOf: string | null;
        name: string;
        workspace: string;
        provider: string;
      }>),
      ...(saveCustomEmoji.mock.calls[1][0] as Array<{
        id: string;
        imageUrl: string | null;
        aliasOf: string | null;
        name: string;
        workspace: string;
        provider: string;
      }>),
    ];
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

  it("nulls out aliasOf when the alias target is a standard (non-custom) emoji", async () => {
    // Slack lets a workspace alias a custom name to a built-in emoji
    // shortcode (e.g. "yes": "alias:thumbsup"). "thumbsup" never gets its
    // own custom_emoji row, so aliasOf pointing at it would violate the
    // self-referencing alias_of foreign key.
    const store = makeStore({});
    const integrationsGet = vi.fn().mockResolvedValue({
      token: "xoxp-test",
      scopes: ["emoji:read"],
      provider: { team_id: "T0" },
    });
    const saveCustomEmoji = vi.fn().mockResolvedValue(undefined);
    const { slack } = makeEmojiSlack({ store, integrationsGet, saveCustomEmoji });

    const fetchMock = mockEmojiListFetch({ yes: "alias:thumbsup" });
    vi.stubGlobal("fetch", fetchMock);
    try {
      await (slack as unknown as {
        syncCustomEmoji: (c: string) => Promise<void>;
      }).syncCustomEmoji("C1");
    } finally {
      vi.unstubAllGlobals();
    }

    // No non-alias rows exist, so only the alias-pass call carries rows.
    const calls = saveCustomEmoji.mock.calls as Array<
      Array<Array<{ id: string; aliasOf: string | null }>>
    >;
    const allRows = calls.flatMap((args) => args[0]);
    const yes = allRows.find((e) => e.id === "slack:T0/yes")!;
    expect(yes).toBeDefined();
    expect(yes.aliasOf).toBeNull();
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

describe("extractSlackMessageReactions (custom emoji)", () => {
  it("emits a slack: ref for a known workspace custom emoji", () => {
    const msg = {
      ts: "1.0",
      user: "U1",
      reactions: [{ name: "party_parrot", users: ["U1", "U2"], count: 2 }],
    } as unknown as SlackMessage;

    const result = extractSlackMessageReactions(
      msg,
      undefined,
      "T0",
      new Set(["party_parrot"])
    );

    expect(result).toBeDefined();
    expect(Object.keys(result!)).toEqual(["slack:T0/party_parrot"]);
    expect(result!["slack:T0/party_parrot"]).toHaveLength(2);
  });

  it("strips a ::skin-tone suffix before matching the custom set", () => {
    const msg = {
      ts: "1.0",
      user: "U1",
      reactions: [{ name: "party_parrot::skin-tone-3", users: ["U1"], count: 1 }],
    } as unknown as SlackMessage;

    const result = extractSlackMessageReactions(
      msg,
      undefined,
      "T0",
      new Set(["party_parrot"])
    );

    expect(result).toBeDefined();
    expect(Object.keys(result!)).toEqual(["slack:T0/party_parrot"]);
  });

  it("still drops a truly-unknown name (not standard, not custom)", () => {
    const msg = {
      ts: "1.0",
      user: "U1",
      reactions: [{ name: "not_a_real_emoji_xyz", users: ["U1"], count: 1 }],
    } as unknown as SlackMessage;

    const result = extractSlackMessageReactions(
      msg,
      undefined,
      "T0",
      new Set(["party_parrot"])
    );

    expect(result).toBeUndefined();
  });

  it("maps a standard unicode reaction without a custom set", () => {
    const msg = {
      ts: "1.0",
      user: "U1",
      reactions: [{ name: "thumbsup", users: ["U1"], count: 1 }],
    } as unknown as SlackMessage;

    const result = extractSlackMessageReactions(msg);
    expect(result).toBeDefined();
    // Standard mapping resolves to a unicode key (not a slack: ref).
    expect(Object.keys(result!)[0]?.startsWith("slack:")).toBe(false);
  });
});

describe("onNoteReactionChanged (custom emoji outbound)", () => {
  it("unwraps a slack: ref to the bare name for reactions.add", async () => {
    const store = makeStore({ sync_enabled_C1: true });
    const integrationsGet = vi.fn().mockResolvedValue({ token: "xoxp-test" });
    const tools = {
      store,
      integrations: { get: integrationsGet },
      network: { createWebhook: vi.fn() },
      files: {},
    };
    const slack = new Slack(
      "twist-instance-1" as never,
      { getTools: () => tools } as never
    );

    const calls: Array<{ method: string; params: URLSearchParams }> = [];
    const fetchMock = vi.fn(async (url: string, init: { body: string }) => {
      calls.push({
        method: String(url).split("/api/")[1] ?? String(url),
        params: new URLSearchParams(init.body),
      });
      return {
        ok: true,
        status: 200,
        headers: { get: () => null },
        json: async () => ({ ok: true }),
      } as never;
    });
    vi.stubGlobal("fetch", fetchMock);
    try {
      await slack.onNoteReactionChanged(
        { key: "111.000" } as never,
        { meta: { channelId: "C1" } } as never,
        { id: "actor-1" } as never,
        "slack:T0/party_parrot",
        true
      );
    } finally {
      vi.unstubAllGlobals();
    }

    const add = calls.find((c) => c.method.startsWith("reactions.add"));
    expect(add).toBeDefined();
    expect(add!.params.get("name")).toBe("party_parrot");
    expect(add!.params.get("channel")).toBe("C1");
    expect(add!.params.get("timestamp")).toBe("111.000");
  });

  it("drops an unknown custom emoji ref with no Slack equivalent", async () => {
    const store = makeStore({ sync_enabled_C1: true });
    const integrationsGet = vi.fn().mockResolvedValue({ token: "xoxp-test" });
    const tools = {
      store,
      integrations: { get: integrationsGet },
      network: { createWebhook: vi.fn() },
      files: {},
    };
    const slack = new Slack(
      "twist-instance-1" as never,
      { getTools: () => tools } as never
    );

    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
    try {
      await slack.onNoteReactionChanged(
        { key: "111.000" } as never,
        { meta: { channelId: "C1" } } as never,
        { id: "actor-1" } as never,
        "not-a-mappable-emoji",
        true
      );
    } finally {
      vi.unstubAllGlobals();
    }

    expect(fetchMock).not.toHaveBeenCalled();
  });
});

describe("startIncrementalSync — coalesced scheduling", () => {
  it("schedules a keyed coalescing task instead of enqueueing per event", async () => {
    const store = makeStore({ channel_webhook_C123: { url: "https://x" } });
    const scheduleTask = vi.fn(async () => "cancel-token");
    const runTask = vi.fn(async () => {});
    const tools = {
      store,
      callbacks: { create: vi.fn(async () => "cb-token") },
      tasks: { scheduleTask, runTask },
      integrations: {},
      network: {},
      files: {},
    };
    const slack = new Slack(
      "twist-instance-1" as never,
      { getTools: () => tools } as never
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ) as any;

    await slack.startIncrementalSync("C123");

    // One Slack event per message must NOT become one queued task per event —
    // the pass is scheduled under a stable per-channel key with coalesce so
    // bursts collapse into a single pending pass.
    expect(runTask).not.toHaveBeenCalled();
    expect(scheduleTask).toHaveBeenCalledTimes(1);
    const [key, , options] = scheduleTask.mock.calls[0] as unknown as [
      string,
      unknown,
      { runAt: Date; coalesce?: boolean },
    ];
    expect(key).toBe("__drain__:incremental-sync:C123");
    expect(options.coalesce).toBe(true);
    expect(options.runAt.getTime()).toBeGreaterThan(Date.now());
  });
});

describe("onSlackWebhook — deauthorization events", () => {
  function makeDeauthSlack(opts: {
    integrationsGet?: ReturnType<typeof vi.fn>;
    markNeedsReauth: ReturnType<typeof vi.fn>;
  }): Slack {
    const tools = {
      store: makeStore(),
      integrations: {
        get: opts.integrationsGet ?? vi.fn().mockResolvedValue(null),
        markNeedsReauth: opts.markNeedsReauth,
      },
      network: {},
      files: {},
    };
    return new Slack(
      "twist-instance-1" as never,
      { getTools: () => tools } as never
    );
  }

  // onSlackWebhook reads request.body.event.
  const req = (event: unknown) => ({ body: { event } }) as never;

  it("flags re-auth when the app is uninstalled from the workspace", async () => {
    const markNeedsReauth = vi.fn().mockResolvedValue(undefined);
    const slack = makeDeauthSlack({ markNeedsReauth });
    await slack.onSlackWebhook(req({ type: "app_uninstalled" }), "C123");
    expect(markNeedsReauth).toHaveBeenCalledWith("C123");
  });

  it("flags re-auth when this connection's own token is revoked", async () => {
    const markNeedsReauth = vi.fn().mockResolvedValue(undefined);
    const integrationsGet = vi.fn().mockResolvedValue({
      token: "xoxp-test",
      provider: { authed_user_id: "U_SELF" },
    });
    const slack = makeDeauthSlack({ integrationsGet, markNeedsReauth });
    await slack.onSlackWebhook(
      req({ type: "tokens_revoked", tokens: { oauth: ["U_SELF"] } }),
      "C123"
    );
    expect(markNeedsReauth).toHaveBeenCalledWith("C123");
  });

  it("ignores tokens_revoked for a different user on the same team", async () => {
    // The event fans out to every callback registered for the team, so a
    // teammate revoking their token must NOT tear down this user's connection.
    const markNeedsReauth = vi.fn().mockResolvedValue(undefined);
    const integrationsGet = vi.fn().mockResolvedValue({
      token: "xoxp-test",
      provider: { authed_user_id: "U_SELF" },
    });
    const slack = makeDeauthSlack({ integrationsGet, markNeedsReauth });
    await slack.onSlackWebhook(
      req({ type: "tokens_revoked", tokens: { oauth: ["U_OTHER"] } }),
      "C123"
    );
    expect(markNeedsReauth).not.toHaveBeenCalled();
  });
});

describe("onChannelEnabled — workspace daily task dedup", () => {
  function makeMultiChannelSlack(storeInitial: Record<string, unknown> = {}) {
    const store = makeStore(storeInitial);
    const create = vi.fn(async () => ({ token: "cb" }) as never);
    const runTask = vi.fn(async () => "task-token");
    const tools = {
      store,
      integrations: {
        get: vi.fn(),
        channelSyncCompleted: vi.fn().mockResolvedValue(undefined),
      },
      network: { createWebhook: vi.fn() },
      files: {},
      callbacks: { create },
      tasks: { runTask, scheduleRecurring: vi.fn(async () => {}) },
    };
    const slack = new Slack(
      "twist-instance-1" as never,
      { getTools: () => tools } as never
    );
    return { slack, store, create, runTask };
  }

  /** Count `create` calls whose callback target is the given method name. */
  function countCallbackCreates(
    create: ReturnType<typeof vi.fn>,
    methodName: string
  ): number {
    return create.mock.calls.filter(
      (call) => (call[0] as { name?: string })?.name === methodName
    ).length;
  }

  it("only the first channel of a fan-out queues syncMembers/syncCustomEmoji", async () => {
    const { slack, create } = makeMultiChannelSlack();
    const channels = [
      { id: "C1", title: "general" },
      { id: "C2", title: "random" },
      { id: "C3", title: "announcements" },
    ];

    for (const channel of channels) {
      await slack.onChannelEnabled(channel as never, undefined);
    }

    expect(countCallbackCreates(create, "syncMembers")).toBe(1);
    expect(countCallbackCreates(create, "syncCustomEmoji")).toBe(1);
  });

  it("does not re-queue on a channel enabled after the daily gate is already set", async () => {
    const { slack, create } = makeMultiChannelSlack({
      membersSyncedAt: Date.now(),
      customEmojiSyncedAt: Date.now(),
    });

    await slack.onChannelEnabled({ id: "C4", title: "new-channel" } as never, undefined);

    expect(countCallbackCreates(create, "syncMembers")).toBe(0);
    expect(countCallbackCreates(create, "syncCustomEmoji")).toBe(0);
  });
});
