import { describe, expect, it, vi } from "vitest";
import { AuthProvider, type Authorization } from "@plotday/twister/tools/integrations";
import { Slack } from "./slack";
import { assembleSlackDmLink } from "./slack-dm";
import {
  extractSlackMessageReactions,
  SlackApi,
  SlackPermanentError,
  SlackRateLimitedError,
  type SlackMessage,
  type SlackUserInfoMap,
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

  it("stars a synced direct conversation, not just one composed from Plot", async () => {
    // Regression test: a DM link built by the sync-in path (assembleSlackDmLink)
    // used to carry no threadTs at all, so starring it from Plot silently did
    // nothing — onThreadToDo bailed out with no error. This runs the actual
    // meta assembleSlackDmLink produces through onThreadToDo end to end, so a
    // regression in either the meta assembly or the write-back breaks it.
    const link = assembleSlackDmLink({
      channelId: "D111",
      counterpartyUserId: "U222",
      messages: [
        { type: "message", ts: "100.0", user: "U222", text: "first" },
        { type: "message", ts: "102.0", user: "U222", text: "third" },
      ] as SlackMessage[],
      initialSync: false,
    });

    const store = makeStore({});
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

    await slack.onThreadToDo({ meta: link?.meta } as never, {} as never, true, {});

    expect(api.addStar).toHaveBeenCalledWith("D111", "102.0");
  });
});

describe("onThreadToDo — direct conversation star anchor", () => {
  function makeStarAnchorSlack(initial: Record<string, unknown> = {}) {
    const store = makeStore(initial);
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
    return { slack, store, api };
  }

  it("unstars the message that was actually starred, not wherever the conversation's anchor has since moved", async () => {
    // A DM's meta.threadTs is the conversation's newest message and moves as
    // it grows. Slack's star, once set, stays on whichever message it was
    // set on — unstarring has to hit that same message, not wherever
    // meta.threadTs points by the time the user unstars.
    const { slack, api } = makeStarAnchorSlack();

    await slack.onThreadToDo(
      { meta: { channelId: "D1", direct: true, threadTs: "100.0" } } as never,
      {} as never,
      true,
      {}
    );
    expect(api.addStar).toHaveBeenCalledWith("D1", "100.0");

    // The conversation grows; a later read of the same thread now reports a
    // newer meta.threadTs.
    await slack.onThreadToDo(
      { meta: { channelId: "D1", direct: true, threadTs: "150.0" } } as never,
      {} as never,
      false,
      {}
    );

    expect(api.removeStar).toHaveBeenCalledWith("D1", "100.0");
  });

  it("falls back to meta.threadTs when unstarring a DM with no recorded anchor", async () => {
    // Covers a DM starred before this anchor mechanism existed, or one
    // whose only star ever came from Slack's own affordance in a version
    // that didn't record an anchor either.
    const { slack, api } = makeStarAnchorSlack();

    await slack.onThreadToDo(
      { meta: { channelId: "D1", direct: true, threadTs: "100.0" } } as never,
      {} as never,
      false,
      {}
    );

    expect(api.removeStar).toHaveBeenCalledWith("D1", "100.0");
  });

  it("clears the anchor once unstarred, so it doesn't outlive the star it names", async () => {
    const { slack, store, api } = makeStarAnchorSlack();

    await slack.onThreadToDo(
      { meta: { channelId: "D1", direct: true, threadTs: "100.0" } } as never,
      {} as never,
      true,
      {}
    );
    expect(store.map.get("star_anchor:D1")).toBe("100.0");

    await slack.onThreadToDo(
      { meta: { channelId: "D1", direct: true, threadTs: "100.0" } } as never,
      {} as never,
      false,
      {}
    );

    expect(store.map.has("star_anchor:D1")).toBe(false);
    expect(api.removeStar).toHaveBeenCalledWith("D1", "100.0");
  });

  it("never touches the anchor for a channel thread, whose threadTs is already fixed", async () => {
    // A channel id can host many independently-starred threads, unlike a DM
    // channel id (which names exactly one conversation) — an anchor keyed
    // only on channelId would corrupt one thread's target with another's.
    // Channel threads don't need the anchor at all: their threadTs never
    // moves, so this also verifies onThreadToDo doesn't write one.
    const { slack, store, api } = makeStarAnchorSlack();

    await slack.onThreadToDo(
      { meta: { channelId: "C1", threadTs: "100.0" } } as never,
      {} as never,
      true,
      {}
    );
    await slack.onThreadToDo(
      { meta: { channelId: "C1", threadTs: "100.0" } } as never,
      {} as never,
      false,
      {}
    );

    expect(store.map.has("star_anchor:C1")).toBe(false);
    expect(api.addStar).toHaveBeenCalledWith("C1", "100.0");
    expect(api.removeStar).toHaveBeenCalledWith("C1", "100.0");
  });
});

describe("applyStarEvent — records the star anchor for a direct conversation", () => {
  it("records the anchor when a DM is starred directly in Slack, not just from Plot", async () => {
    // onThreadToDo records the anchor for a Plot-initiated star. A star set
    // directly in Slack goes through here instead — without the same
    // bookkeeping, a later unstar from Plot would fall back to
    // meta.threadTs (which may have moved on since) rather than the message
    // Slack actually has starred.
    const store = makeStore({
      auth_actor_id: "actor-1",
      dm_channels: ["D1"],
      dm_conversations: { D1: { user: "U2" } },
    });
    const tools = {
      store,
      integrations: { get: vi.fn(), setThreadToDo: vi.fn() },
      network: {},
      files: {},
      callbacks: { create: vi.fn(async () => ({ token: "cb" }) as never) },
      tasks: {
        scheduleTask: vi.fn(async () => "t"),
        runTask: vi.fn(async () => {}),
      },
    };
    const slack = new Slack(
      "twist-instance-1" as never,
      { getTools: () => tools } as never
    );
    vi.spyOn(
      slack as unknown as { getApi: (c: string) => Promise<unknown> },
      "getApi"
    ).mockResolvedValue({});
    vi.spyOn(slack as any, "saveStarredThread").mockResolvedValue(undefined);

    await slack.applyStarEvent("D1", "50.0", true);

    expect(store.map.get("star_anchor:D1")).toBe("50.0");
  });

  it("clears the anchor when the DM's to-do is cleared via Slack", async () => {
    const store = makeStore({
      auth_actor_id: "actor-1",
      dm_channels: ["D1"],
      dm_conversations: { D1: { user: "U2" } },
      "star_anchor:D1": "50.0",
    });
    const setThreadToDo = vi.fn().mockResolvedValue(undefined);
    const tools = {
      store,
      integrations: { get: vi.fn(), setThreadToDo },
      network: {},
      files: {},
      callbacks: { create: vi.fn(async () => ({ token: "cb" }) as never) },
      tasks: {
        scheduleTask: vi.fn(async () => "t"),
        runTask: vi.fn(async () => {}),
      },
    };
    const slack = new Slack(
      "twist-instance-1" as never,
      { getTools: () => tools } as never
    );

    await slack.applyStarEvent("D1", "50.0", false);

    expect(store.map.has("star_anchor:D1")).toBe(false);
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

  it("signals completion before running the best-effort upgrade cleanup", async () => {
    // channelSyncCompleted must fire even if a later step in this method
    // throws — otherwise the stuck-sync watchdog eventually forces a
    // re-auth prompt on a healthy connection. The upgrade cleanup is
    // internally non-throwing, but its call is still placed physically
    // after this signal as a second line of defense that doesn't depend on
    // that internal try/catch staying intact.
    const { slack, channelSyncCompleted } = makeOnChannelEnabledSlack();
    const order: string[] = [];
    channelSyncCompleted.mockImplementation(async () => {
      order.push("channelSyncCompleted");
    });
    vi.spyOn(
      slack as unknown as { upgradeToScopedSync: () => Promise<void> },
      "upgradeToScopedSync"
    ).mockImplementation(async () => {
      order.push("upgradeToScopedSync");
    });

    await slack.onChannelEnabled(channel as never, undefined);

    expect(order).toEqual(["channelSyncCompleted", "upgradeToScopedSync"]);
  });
});

describe("upgrade — deploy-time migration trigger", () => {
  it("migrates a pre-existing token registry with no onChannelEnabled dispatch involved", async () => {
    // getWorkspaceApi / findChannelForFile start reading token_channel_ the
    // moment this version deploys, but a stable, already-connected
    // workspace never re-dispatches onChannelEnabled (no channel changes
    // state), so that path alone would leave such a connection's registry
    // un-migrated indefinitely. upgrade() is the hook the platform actually
    // calls once per connection on deploy — migration has to run from
    // there, not only as an onChannelEnabled backstop.
    const store = makeStore({ sync_enabled_C1: true });
    const slack = makeSlack({
      store,
      integrationsGet: vi.fn(),
      createWebhook: vi.fn(),
    });

    await slack.upgrade();

    expect(store.map.get("token_channel_C1")).toBe(true);
    expect(store.map.has("sync_enabled_C1")).toBe(false);
  });
});

describe("onChannelEnabled — workspace webhook registration", () => {
  function makeSetupSlack() {
    const store = makeStore({});
    const create = vi.fn(async (fn: { name?: string }) => ({
      token: fn?.name ?? "cb",
    }) as never);
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
    return { slack, create, store };
  }

  /** Names of the methods `onChannelEnabled` tokenised into callbacks. */
  function queuedMethods(create: ReturnType<typeof vi.fn>): string[] {
    return create.mock.calls.map(
      (call) => (call[0] as { name?: string })?.name ?? ""
    );
  }

  it("queues both workspace-wide webhook registrations", async () => {
    // These are the ONLY registrations this connector makes: one callback for
    // direct conversations, one for everything else. Nothing registers per
    // channel, so if either is not queued here it is never registered at all
    // and that half of the connection silently syncs nothing.
    const { slack, create } = makeSetupSlack();

    await slack.onChannelEnabled({ id: "C123", title: "general" } as never, undefined);

    expect(queuedMethods(create)).toEqual(
      expect.arrayContaining(["registerDMWebhook", "registerMentionWebhook"])
    );
  });

  it("registers both webhooks even for an observe-only channel", async () => {
    // observeOnly means the channel was auto-observed because a Plot thread
    // was composed into it. Go-forward events still matter; only the
    // saved-item backfill is skipped.
    const { slack, create } = makeSetupSlack();

    await slack.onChannelEnabled(
      { id: "C123", title: "general" } as never,
      { observeOnly: true } as never
    );

    expect(queuedMethods(create)).toEqual(
      expect.arrayContaining(["registerDMWebhook", "registerMentionWebhook"])
    );
    expect(queuedMethods(create)).not.toContain("backfillStars");
  });

  it("queues each registration once across a whole fan-out", async () => {
    // Channels are hidden, so every channel the user belongs to is enabled
    // and this fires once per channel. Queuing a registration per channel
    // would spend a queue dispatch and a worker invocation apiece for work
    // that can only happen once per connection.
    const { slack, create } = makeSetupSlack();

    for (const id of ["C1", "C2", "C3"]) {
      await slack.onChannelEnabled({ id, title: id } as never, undefined);
    }

    const queued = queuedMethods(create);
    expect(queued.filter((m) => m === "registerDMWebhook")).toHaveLength(1);
    expect(queued.filter((m) => m === "registerMentionWebhook")).toHaveLength(1);
  });

  it("records the channel so a direct conversation can still resolve a token", async () => {
    // A direct conversation's id is not a channel, so it can never resolve an
    // OAuth token on its own. getWorkspaceApi falls back to walking the
    // channel ids recorded here; without them, every reply on a synced DM
    // fails to send.
    const { slack, store } = makeSetupSlack();

    await slack.onChannelEnabled({ id: "C123", title: "general" } as never, undefined);

    expect(store.map.get("token_channel_C123")).toBe(true);
  });

  it("migrates a pre-existing legacy token registry entry for the whole connection, not just the channel being enabled", async () => {
    // onChannelEnabled fires per-channel on mirror, but the upgrade it
    // triggers is connection-wide: a channel enabled long before this
    // deploy (and not part of THIS mirror pass) must still come out with a
    // working token-registry entry, not just the channel in hand.
    const store = makeStore({ sync_enabled_C1: true });
    const create = vi.fn(async (fn: { name?: string }) => ({
      token: fn?.name ?? "cb",
    }) as never);
    const tools = {
      store,
      integrations: {
        get: vi.fn(),
        channelSyncCompleted: vi.fn().mockResolvedValue(undefined),
      },
      network: { createWebhook: vi.fn() },
      files: {},
      callbacks: { create },
      tasks: {
        runTask: vi.fn(async () => "task-token"),
        scheduleRecurring: vi.fn(async () => {}),
      },
    };
    const slack = new Slack(
      "twist-instance-1" as never,
      { getTools: () => tools } as never
    );

    await slack.onChannelEnabled({ id: "C123", title: "general" } as never, undefined);

    expect(store.map.get("token_channel_C1")).toBe(true);
    expect(store.map.get("token_channel_C123")).toBe(true);
    expect(store.map.has("sync_enabled_C1")).toBe(false);
  });
});

describe("upgradeToScopedSync", () => {
  it("removes per-channel webhooks and sync state exactly once", async () => {
    const store = makeStore({
      channel_webhook_C1: { url: "https://hook/1", channelId: "C1" },
      sync_enabled_C1: true,
      sync_state_C1: { channelId: "C1" },
      enabled_at_C1: "100.0",
    });
    const deleteWebhook = vi.fn().mockResolvedValue(undefined);
    const slack = makeSlack({
      store,
      integrationsGet: vi.fn(),
      createWebhook: vi.fn(),
    });
    (slack as any).tools.network.deleteWebhook = deleteWebhook;

    await (slack as any).upgradeToScopedSync();
    await (slack as any).upgradeToScopedSync();

    expect(deleteWebhook).toHaveBeenCalledTimes(1);
    expect(store.map.has("channel_webhook_C1")).toBe(false);
    expect(store.map.has("sync_enabled_C1")).toBe(false);
    expect(store.map.has("sync_state_C1")).toBe(false);
    expect(store.map.has("enabled_at_C1")).toBe(false);
    expect(store.map.get("scoped_sync_upgraded")).toBe(true);
    // The token registry is a rename, not a drop: attachment lookups and DM
    // replies must keep working under the connection's new key.
    expect(store.map.get("token_channel_C1")).toBe(true);
  });

  it("does not mark the upgrade done when a step partway through fails", async () => {
    // scoped_sync_upgraded means "the whole pass completed" — marking it on
    // a partial failure would make the guard skip ever retrying the rest of
    // a connection's leftover state, stranding it permanently.
    const store = makeStore({
      sync_enabled_C1: true,
      sync_enabled_C2: true,
    });
    store.set = vi.fn(async (key: string, value: unknown) => {
      if (key === "token_channel_C2") throw new Error("storage blip");
      store.map.set(key, value);
    });
    const slack = makeSlack({
      store,
      integrationsGet: vi.fn(),
      createWebhook: vi.fn(),
    });

    await (slack as any).upgradeToScopedSync();

    expect(store.map.get("scoped_sync_upgraded")).toBeUndefined();
  });

  it("absorbs a failure of its own guard read", async () => {
    // The guard read runs on EVERY call for the life of the connection, and
    // `onChannelEnabled` awaits this before queuing the saved-items backfill
    // and the workspace tasks (webhook registration included). A blip on it
    // escaping would take all of that with it.
    const store = makeStore({ scoped_sync_upgraded: true });
    store.get = vi.fn(async () => {
      throw new Error("storage blip");
    });
    const slack = makeSlack({
      store,
      integrationsGet: vi.fn(),
      createWebhook: vi.fn(),
    });

    await expect(
      (slack as any).upgradeToScopedSync()
    ).resolves.toBeUndefined();
  });

  it("completes the rest of the migration even when a webhook fails to delete", async () => {
    // The whole routine is documented as best-effort; this exercises the
    // "best-effort" part directly by making deleteWebhook actually reject,
    // rather than just relying on it never being made to fail.
    const store = makeStore({
      channel_webhook_C1: { url: "https://hook/1", channelId: "C1" },
      sync_enabled_C1: true,
      sync_state_C1: { channelId: "C1" },
    });
    const deleteWebhook = vi.fn().mockRejectedValue(new Error("already gone"));
    const slack = makeSlack({
      store,
      integrationsGet: vi.fn(),
      createWebhook: vi.fn(),
    });
    (slack as any).tools.network.deleteWebhook = deleteWebhook;

    await (slack as any).upgradeToScopedSync();

    expect(deleteWebhook).toHaveBeenCalledTimes(1);
    expect(store.map.has("channel_webhook_C1")).toBe(false);
    expect(store.map.has("sync_state_C1")).toBe(false);
    expect(store.map.get("token_channel_C1")).toBe(true);
    expect(store.map.get("scoped_sync_upgraded")).toBe(true);
  });

  it("short-circuits once scoped_sync_upgraded is already set, touching nothing", async () => {
    // A connection can pick up unrelated state after its one-time upgrade
    // ran (e.g. a webhook re-registered by some other path). The guard must
    // treat "already upgraded" as final and leave such state alone, not
    // sweep it on every later onChannelEnabled call.
    const store = makeStore({
      scoped_sync_upgraded: true,
      channel_webhook_C9: { url: "https://hook/9", channelId: "C9" },
    });
    const deleteWebhook = vi.fn().mockResolvedValue(undefined);
    const slack = makeSlack({
      store,
      integrationsGet: vi.fn(),
      createWebhook: vi.fn(),
    });
    (slack as any).tools.network.deleteWebhook = deleteWebhook;

    await (slack as any).upgradeToScopedSync();

    expect(deleteWebhook).not.toHaveBeenCalled();
    expect(store.map.get("channel_webhook_C9")).toBeDefined();
  });

  it("renames every enabled channel's token-registry entry, not just the one whose onChannelEnabled triggered the upgrade", async () => {
    // The upgrade runs once per CONNECTION (gated on scoped_sync_upgraded),
    // triggered by whichever channel's onChannelEnabled fires first in a
    // mirror fan-out. Every other channel this connection ever enabled has
    // to come out the other side still resolvable, not just that one.
    const store = makeStore({
      sync_enabled_C1: true,
      sync_enabled_C2: true,
    });
    const slack = makeSlack({
      store,
      integrationsGet: vi.fn(),
      createWebhook: vi.fn(),
    });

    await (slack as any).upgradeToScopedSync();

    expect(store.map.get("token_channel_C1")).toBe(true);
    expect(store.map.get("token_channel_C2")).toBe(true);
    expect(store.map.has("sync_enabled_C1")).toBe(false);
    expect(store.map.has("sync_enabled_C2")).toBe(false);
  });

  it("lets getWorkspaceApi's fallback resolve a token through the renamed registry after migration", async () => {
    // Before the fix, this connection only had the legacy sync_enabled_
    // key. If the rename silently dropped it instead, a reply on a synced
    // DM (which always falls back through getWorkspaceApi, since a DM id
    // resolves no direct token) would fail with no enabled channels found.
    const store = makeStore({ sync_enabled_C1: true });
    const integrationsGet = vi.fn(async (channelId: string) =>
      channelId === "C1" ? { token: "xoxp-c1" } : null
    );
    const slack = makeSlack({ store, integrationsGet, createWebhook: vi.fn() });

    await (slack as any).upgradeToScopedSync();

    const api = await (slack as any).getWorkspaceApi("D1");
    expect(api.accessToken).toBe("xoxp-c1");
  });

  it("lets findChannelForFile probe the renamed registry after migration", async () => {
    // Same failure mode as getWorkspaceApi, on the attachment-download path:
    // an uncached inbound file has no channel to probe without the
    // registry, so a dropped-instead-of-renamed key would silently break
    // every uncached attachment download for an upgraded connection.
    const store = makeStore({ sync_enabled_C1: true });
    const slack = makeSlack({
      store,
      integrationsGet: vi.fn().mockResolvedValue({ token: "xoxp-c1" }),
      createWebhook: vi.fn(),
    });
    const call = vi.fn().mockResolvedValue({ file: { id: "F1" } });
    vi.spyOn(
      slack as unknown as { getApi: (c: string) => Promise<unknown> },
      "getApi"
    ).mockResolvedValue({ call } as never);

    await (slack as any).upgradeToScopedSync();

    const channelId = await (slack as any).findChannelForFile("F1");

    expect(channelId).toBe("C1");
    expect(store.map.get("slack:file-channel:F1")).toBe("C1");
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

describe("syncUserGroups", () => {
  /** Build a Slack with the tool set needed by syncUserGroups. */
  function makeUserGroupsSlack(opts: {
    store: ReturnType<typeof makeStore>;
    integrationsGet: ReturnType<typeof vi.fn>;
    markNeedsReauth?: ReturnType<typeof vi.fn>;
  }) {
    const create = vi.fn(async () => ({ token: "cb" }) as never);
    const runTask = vi.fn(async () => "task-token");
    const scheduleRecurring = vi.fn(async () => {});
    const markNeedsReauth = opts.markNeedsReauth ?? vi.fn(async () => {});
    const tools = {
      store: opts.store,
      integrations: { get: opts.integrationsGet, markNeedsReauth },
      network: { createWebhook: vi.fn() },
      files: {},
      callbacks: { create },
      tasks: { runTask, scheduleRecurring },
    };
    const slack = new Slack(
      "twist-instance-1" as never,
      { getTools: () => tools } as never
    );
    return { slack, create, runTask, scheduleRecurring, markNeedsReauth };
  }

  /** Mock global.fetch to answer one `usergroups.list` call with `usergroups`. */
  function mockUserGroupsListFetch(
    usergroups: Array<{ id: string; users?: string[] }>
  ) {
    return vi.fn(async () =>
      ({
        ok: true,
        status: 200,
        headers: { get: () => null },
        json: async () => ({ ok: true, usergroups }),
      }) as never
    );
  }

  it("caches the group roster and gates re-runs to once per 24h", async () => {
    const store = makeStore({});
    const integrationsGet = vi.fn().mockResolvedValue({
      token: "xoxp-test",
      scopes: ["usergroups:read"],
      provider: { authed_user_id: "U111" },
    });
    const { slack, scheduleRecurring } = makeUserGroupsSlack({
      store,
      integrationsGet,
    });

    const fetchMock = mockUserGroupsListFetch([{ id: "S222", users: ["U111"] }]);
    vi.stubGlobal("fetch", fetchMock);
    try {
      await (slack as unknown as {
        syncUserGroups: (c: string) => Promise<void>;
      }).syncUserGroups("C1");
      expect(fetchMock).toHaveBeenCalledTimes(1);
      expect(store.map.get("slack_user_groups")).toEqual(["S222"]);
      expect(store.map.has("userGroupsSyncedAt")).toBe(true);
      expect(scheduleRecurring).toHaveBeenCalledTimes(1);

      // Second call within 24h should not re-fetch: the daily gate at the
      // top of syncUserGroups must short-circuit on the timestamp it just
      // wrote, exactly like syncMembers/syncCustomEmoji do for their own
      // caches.
      await (slack as unknown as {
        syncUserGroups: (c: string) => Promise<void>;
      }).syncUserGroups("C1");
      expect(fetchMock).toHaveBeenCalledTimes(1);
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it("leaves the timestamp unset and reschedules sooner when rate limited", async () => {
    const store = makeStore({});
    const integrationsGet = vi.fn().mockResolvedValue({
      token: "xoxp-test",
      scopes: ["usergroups:read"],
      provider: { authed_user_id: "U111" },
    });
    const { slack, scheduleRecurring, markNeedsReauth } = makeUserGroupsSlack({
      store,
      integrationsGet,
    });

    // HTTP 429 with a retry-after long enough (>2s) that `call()` throws
    // SlackRateLimitedError instead of sleeping and retrying in-process.
    const fetchMock = vi.fn(async () =>
      ({
        ok: false,
        status: 429,
        headers: { get: (h: string) => (h === "retry-after" ? "5" : null) },
        json: async () => ({}),
      }) as never
    );
    vi.stubGlobal("fetch", fetchMock);
    try {
      await (slack as unknown as {
        syncUserGroups: (c: string) => Promise<void>;
      }).syncUserGroups("C1");

      // Not marked done: the cache and timestamp are both untouched, and
      // reauth is not flagged for a rate limit.
      expect(store.map.has("userGroupsSyncedAt")).toBe(false);
      expect(store.map.has("slack_user_groups")).toBe(false);
      expect(markNeedsReauth).not.toHaveBeenCalled();

      // Rescheduled sooner than the daily cadence, under the same per-channel
      // key as the daily chain (so a later successful daily run can't race
      // it into two parallel chains).
      expect(scheduleRecurring).toHaveBeenCalledTimes(1);
      const [key, , options] = scheduleRecurring.mock.calls[0] as unknown as [
        string,
        unknown,
        { intervalMs: number; firstRunAt: Date },
      ];
      expect(key).toBe("user-groups-sync:C1");
      expect(options.firstRunAt.getTime()).toBeLessThan(Date.now() + 24 * 60 * 60 * 1000);

      // No timestamp was written, so a second direct call is not gated — it
      // retries immediately instead of waiting out a 24h window the failed
      // pass never earned.
      await (slack as unknown as {
        syncUserGroups: (c: string) => Promise<void>;
      }).syncUserGroups("C1");
      expect(fetchMock).toHaveBeenCalledTimes(2);
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it("flags reauth when the API rejects the call with an auth-type permanent error", async () => {
    const store = makeStore({});
    const integrationsGet = vi.fn().mockResolvedValue({
      token: "xoxp-test",
      scopes: ["usergroups:read"],
      provider: { authed_user_id: "U111" },
    });
    const { slack, scheduleRecurring, markNeedsReauth } = makeUserGroupsSlack({
      store,
      integrationsGet,
    });

    // token_revoked is in SLACK_AUTH_ERRORS: the grant itself is bad, so
    // this is not something a retry (or waiting for the user) will fix.
    const fetchMock = vi.fn(async () =>
      ({
        ok: true,
        status: 200,
        headers: { get: () => null },
        json: async () => ({ ok: false, error: "token_revoked" }),
      }) as never
    );
    vi.stubGlobal("fetch", fetchMock);
    try {
      await (slack as unknown as {
        syncUserGroups: (c: string) => Promise<void>;
      }).syncUserGroups("C1");

      expect(markNeedsReauth).toHaveBeenCalledWith("C1");
      expect(store.map.has("userGroupsSyncedAt")).toBe(false);
      expect(scheduleRecurring).not.toHaveBeenCalled();
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it("does NOT flag reauth when the optional scope was simply declined", async () => {
    // Guards the distinction the auth-error test above depends on: a token
    // that never carries usergroups:read (the user declined the optional
    // grant, or connected before the scope group existed) must be treated
    // as a quiet no-op, not a broken connection. The check happens
    // client-side, before any API call — so the connector never even sees
    // Slack's own missing_scope error for this case.
    const store = makeStore({});
    const integrationsGet = vi.fn().mockResolvedValue({
      token: "xoxp-test",
      scopes: ["channels:history"], // no usergroups:read
      provider: { authed_user_id: "U111" },
    });
    const { slack, scheduleRecurring, markNeedsReauth } = makeUserGroupsSlack({
      store,
      integrationsGet,
    });

    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
    try {
      await (slack as unknown as {
        syncUserGroups: (c: string) => Promise<void>;
      }).syncUserGroups("C1");

      expect(fetchMock).not.toHaveBeenCalled();
      expect(markNeedsReauth).not.toHaveBeenCalled();
      expect(scheduleRecurring).not.toHaveBeenCalled();
      // The marker IS stamped: a declined optional grant cannot change
      // without a reconnect, so leaving it unset would make the daily
      // fan-out re-queue a pass that can only return here again.
      expect(store.map.get("userGroupsSyncedAt")).toEqual(expect.any(Number));
      // ...but the connected identity is still refreshed. Declining the group
      // scope only costs group mentions; direct mentions must keep working.
      expect(store.map.get("slack_user_id")).toBe("U111");
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it("refreshes the cached identity the mention router reads", async () => {
    // The router reads `slack_user_id` from the store on every inbound
    // channel message. It is otherwise written exactly once, when the mention
    // webhook first registers — one write for the life of the connection.
    const store = makeStore({});
    const integrationsGet = vi.fn().mockResolvedValue({
      token: "xoxp-test",
      scopes: ["usergroups:read"],
      provider: { authed_user_id: "U111" },
    });
    const { slack } = makeUserGroupsSlack({ store, integrationsGet });

    const fetchMock = mockUserGroupsListFetch([{ id: "S222", users: ["U111"] }]);
    vi.stubGlobal("fetch", fetchMock);
    try {
      await (slack as unknown as {
        syncUserGroups: (c: string) => Promise<void>;
      }).syncUserGroups("C1");
    } finally {
      vi.unstubAllGlobals();
    }

    expect(store.map.get("slack_user_id")).toBe("U111");
  });

  it("propagates an unexpected error instead of swallowing it", async () => {
    // internal_error is neither `ratelimited` nor in PERMANENT_SLACK_ERRORS,
    // so `call()` throws a bare Error — the "genuinely unexpected" case that
    // must reach the platform's automatic error-tracking capture rather than
    // being logged locally and dropped.
    const store = makeStore({});
    const integrationsGet = vi.fn().mockResolvedValue({
      token: "xoxp-test",
      scopes: ["usergroups:read"],
      provider: { authed_user_id: "U111" },
    });
    const { slack, scheduleRecurring, markNeedsReauth } = makeUserGroupsSlack({
      store,
      integrationsGet,
    });

    const fetchMock = vi.fn(async () =>
      ({
        ok: true,
        status: 200,
        headers: { get: () => null },
        json: async () => ({ ok: false, error: "internal_error" }),
      }) as never
    );
    vi.stubGlobal("fetch", fetchMock);
    try {
      await expect(
        (slack as unknown as {
          syncUserGroups: (c: string) => Promise<void>;
        }).syncUserGroups("C1")
      ).rejects.toThrow(/internal_error/);

      expect(store.map.has("userGroupsSyncedAt")).toBe(false);
      expect(markNeedsReauth).not.toHaveBeenCalled();
      expect(scheduleRecurring).not.toHaveBeenCalled();
    } finally {
      vi.unstubAllGlobals();
    }
  });
});

describe("SlackApi.getDMConversations", () => {
  it("calls conversations.list with types=im,mpim and returns conversations", async () => {
    const fetchMock = vi.fn(async () =>
      ({
        ok: true,
        status: 200,
        headers: { get: () => null },
        json: async () => ({
          ok: true,
          channels: [
            { id: "D1", is_im: true, is_mpim: false, user: "U1" },
            { id: "G1", is_im: false, is_mpim: true },
          ],
        }),
      }) as never
    );
    vi.stubGlobal("fetch", fetchMock);
    try {
      const api = new SlackApi("xoxp-test");
      const result = await api.getDMConversations();
      expect(result.conversations).toEqual([
        { id: "D1", is_im: true, is_mpim: false, user: "U1" },
        { id: "G1", is_im: false, is_mpim: true },
      ]);
      const [, requestInit] = fetchMock.mock.calls[0] as unknown as [
        string,
        RequestInit,
      ];
      const body = (requestInit.body as string) ?? "";
      expect(body).toContain("types=im%2Cmpim");
    } finally {
      vi.unstubAllGlobals();
    }
  });
});

describe("listDMChannels", () => {
  function makeDMListSlack(opts: {
    store: ReturnType<typeof makeStore>;
    integrationsGet: ReturnType<typeof vi.fn>;
  }) {
    const runTask = vi.fn(async () => "task-token");
    const create = vi.fn(async () => ({ token: "cb" }) as never);
    const tools = {
      store: opts.store,
      integrations: { get: opts.integrationsGet },
      network: { createWebhook: vi.fn() },
      files: {},
      callbacks: { create },
      tasks: { runTask, scheduleRecurring: vi.fn(async () => {}) },
    };
    return new Slack("twist-instance-1" as never, { getTools: () => tools } as never);
  }

  it("caches discovered im/mpim channel ids and gates re-runs to once per 24h", async () => {
    const store = makeStore({});
    const integrationsGet = vi.fn().mockResolvedValue({
      token: "xoxp-test",
      scopes: ["im:read", "mpim:read"],
    });
    const slack = makeDMListSlack({ store, integrationsGet });

    const fetchMock = vi.fn(async () =>
      ({
        ok: true,
        status: 200,
        headers: { get: () => null },
        json: async () => ({
          ok: true,
          channels: [{ id: "D1", is_im: true, is_mpim: false, user: "U1" }],
        }),
      }) as never
    );
    vi.stubGlobal("fetch", fetchMock);
    try {
      await (slack as unknown as {
        listDMChannels: (c: string) => Promise<void>;
      }).listDMChannels("C1");
      expect(store.map.get("dm_channels")).toEqual(["D1"]);
      // The counterparty is captured in the same pass so the sync path can
      // key a 1:1 on the person without a second API call.
      expect(store.map.get("dm_conversations")).toEqual({ D1: { user: "U1" } });
      expect(fetchMock).toHaveBeenCalledTimes(1);

      // Second call within 24h should not re-fetch.
      await (slack as unknown as {
        listDMChannels: (c: string) => Promise<void>;
      }).listDMChannels("C1");
      expect(fetchMock).toHaveBeenCalledTimes(1);
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it("no-ops when im:read is not granted, without calling the API or flagging re-auth", async () => {
    // Guards against the false-positive-reconnect bug class this branch
    // otherwise fixes: without this guard, a token missing im:read hits
    // conversations.list, gets `missing_scope` back (a SlackPermanentError
    // in SLACK_AUTH_ERRORS), and markNeedsReauth force-flags the whole
    // connection as needing reconnection even though nothing is broken.
    const store = makeStore({});
    const integrationsGet = vi.fn().mockResolvedValue({
      token: "xoxp-test",
      scopes: ["channels:history"], // no im:read
    });
    const markNeedsReauth = vi.fn().mockResolvedValue(undefined);
    const runTask = vi.fn(async () => "task-token");
    const create = vi.fn(async () => ({ token: "cb" }) as never);
    const tools = {
      store,
      integrations: { get: integrationsGet, markNeedsReauth },
      network: { createWebhook: vi.fn() },
      files: {},
      callbacks: { create },
      tasks: { runTask, scheduleRecurring: vi.fn(async () => {}) },
    };
    const slack = new Slack("twist-instance-1" as never, { getTools: () => tools } as never);

    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
    try {
      await (slack as unknown as {
        listDMChannels: (c: string) => Promise<void>;
      }).listDMChannels("C1");
    } finally {
      vi.unstubAllGlobals();
    }

    expect(fetchMock).not.toHaveBeenCalled();
    expect(markNeedsReauth).not.toHaveBeenCalled();
    expect(store.map.has("dm_channels")).toBe(false);
  });

  it("flags re-auth when the token has im:history but not im:read (opted into DMs on a pre-im:read grant)", async () => {
    // A token granted before im:read/mpim:read joined the `dms` scope group
    // carries im:history but not im:read. That user OPTED IN to DM sync, so
    // silently no-oping strands them: the DM webhook registers (it only needs
    // im:history), but listDMChannels never populates `dm_channels`, so
    // isKnownDMChannel rejects every incoming DM event forever — while the
    // connection still reports itself healthy. Both scopes come from the same
    // group, so im:history-without-im:read can only mean a stale grant, never
    // a decline; prompt a reconnect to re-consent.
    const store = makeStore({});
    const integrationsGet = vi.fn().mockResolvedValue({
      token: "xoxp-test",
      scopes: ["channels:history", "im:history", "im:write", "mpim:history"], // pre-fix grant
    });
    const markNeedsReauth = vi.fn().mockResolvedValue(undefined);
    const create = vi.fn(async () => ({ token: "cb" }) as never);
    const tools = {
      store,
      integrations: { get: integrationsGet, markNeedsReauth },
      network: { createWebhook: vi.fn() },
      files: {},
      callbacks: { create },
      tasks: { runTask: vi.fn(async () => "task-token"), scheduleRecurring: vi.fn(async () => {}) },
    };
    const slack = new Slack("twist-instance-1" as never, { getTools: () => tools } as never);

    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
    try {
      await (slack as unknown as {
        listDMChannels: (c: string) => Promise<void>;
      }).listDMChannels("C1");
    } finally {
      vi.unstubAllGlobals();
    }

    // Still no API call: the grant genuinely lacks the enumeration scope, so
    // conversations.list would only return missing_scope.
    expect(fetchMock).not.toHaveBeenCalled();
    // ...but unlike a decline, surface it so the user can reconnect.
    expect(markNeedsReauth).toHaveBeenCalledWith("C1");
    expect(store.map.has("dm_channels")).toBe(false);
  });
});

describe("extractSlackMessageReactions (custom emoji)", () => {
  it("emits a slack: ref for a known workspace custom emoji", () => {
    const msg = {
      ts: "1.0",
      user: "U1",
      reactions: [{ name: "party_parrot", users: ["U1", "U2"], count: 2 }],
    } as unknown as SlackMessage;
    // Reactors need resolvable user info: with no info at all,
    // slackUserToNewActor returns null (no raw-id fallback) and unresolved
    // reactors are filtered out of the reaction's actor list.
    const userInfos: SlackUserInfoMap = new Map([
      ["U1", { name: "User One", email: null, handle: "user1" }],
      ["U2", { name: "User Two", email: null, handle: "user2" }],
    ]);

    const result = extractSlackMessageReactions(
      msg,
      userInfos,
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
    const store = makeStore({ token_channel_C1: true });
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
    const store = makeStore({ token_channel_C1: true });
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
    const store = makeStore({});
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

describe("connector declaration — sync scope is not a channel choice", () => {
  it("hides its channels", () => {
    // Nothing in the connect/edit modal picks channels: what syncs is decided
    // per message (a direct conversation, an at-mention, a saved thread).
    expect(new Slack("t" as never, { getTools: () => ({}) } as never)
      .hiddenChannels).toBe(true);
  });

  it("keeps auto-enabling newly discovered channels", () => {
    // With no picker, nothing else ever enables a channel — and enabling is
    // what dispatches onChannelEnabled, where every piece of workspace setup
    // is anchored. Without this a fresh connection registers no webhooks and
    // syncs nothing at all.
    expect(new Slack("t" as never, { getTools: () => ({}) } as never)
      .autoEnableNewChannelsByDefault).toBe(true);
  });

  it("does not offer the auto-threading preference", () => {
    // Channel threads keep Slack's own structure, and a direct conversation
    // is already assembled as one link — so there is nothing for the
    // "group related messages" toggle to do.
    expect(
      (
        new Slack("t" as never, { getTools: () => ({}) } as never) as unknown as {
          autoThreading?: boolean;
        }
      ).autoThreading
    ).toBeUndefined();
  });
});

describe("Slack.SCOPES — DM sync is optional and opt-in", () => {
  it("does not require im/mpim scopes", () => {
    expect(Slack.SCOPES.required).not.toContain("im:history");
    expect(Slack.SCOPES.required).not.toContain("im:write");
    expect(Slack.SCOPES.required).not.toContain("mpim:history");
    expect(Slack.SCOPES.required).not.toContain("mpim:write");
  });

  it("declares a dms optional group covering im/mpim scopes, default on", () => {
    const dmsGroup = Slack.SCOPES.optional?.find((g) => g.id === "dms");
    expect(dmsGroup).toBeDefined();
    expect(dmsGroup?.scopes).toEqual(
      expect.arrayContaining(["im:history", "im:write", "mpim:history", "mpim:write"])
    );
    expect(dmsGroup?.default).toBe(true);
  });

  it("declares im:read and mpim:read in the dms group, required to enumerate/list DM conversations", () => {
    // conversations.list with types=im,mpim (used by listDMChannels to
    // discover DM/MPIM conversation ids) requires im:read/mpim:read per
    // Slack's API docs — distinct from im:history/mpim:history, which only
    // grant reading message content within an already-known conversation.
    // Without these, listDMChannels gets `missing_scope` on every call.
    const dmsGroup = Slack.SCOPES.optional?.find((g) => g.id === "dms");
    expect(dmsGroup).toBeDefined();
    expect(dmsGroup?.scopes).toEqual(expect.arrayContaining(["im:read", "mpim:read"]));
  });

  it("declares a usergroups optional group so group mentions can be recognised", () => {
    // syncUserGroups checks the granted scopes for usergroups:read before
    // calling the API. Without a group declaring it, no connection ever
    // grants it and a mention of @engineering never counts as a mention.
    const group = Slack.SCOPES.optional?.find((g) => g.id === "usergroups");
    expect(group).toBeDefined();
    expect(group?.scopes).toEqual(["usergroups:read"]);
    expect(group?.default).toBe(true);
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
    // The webhook registrations are one-time, not daily, and carry their own
    // gates — a satisfied daily gate must not suppress them. An early return
    // added above them would leave every other assertion here passing while
    // the connection observes nothing at all.
    expect(countCallbackCreates(create, "registerDMWebhook")).toBe(1);
    expect(countCallbackCreates(create, "registerMentionWebhook")).toBe(1);
  });

  it("re-queues once the claim window has expired and the real gate was never set (e.g. a prior queued task failed permanently)", async () => {
    // Simulates: an earlier onChannelEnabled fan-out claimed and queued
    // syncMembers/syncCustomEmoji, but those queued tasks failed permanently
    // (e.g. SlackPermanentError) and returned before ever reaching their own
    // `this.set("membersSyncedAt", ...)` / `this.set("customEmojiSyncedAt", ...)`.
    // The real 24h gate is therefore still unset, and the claim from that
    // earlier attempt is now stale (older than CLAIM_TTL_MS). A later
    // onChannelEnabled (e.g. the user reconnects after fixing auth) must be
    // allowed to re-queue rather than silently stay stalled for up to 24h.
    const staleClaim = Date.now() - 6 * 60 * 1000; // 6 min ago > 5 min TTL
    const { slack, create } = makeMultiChannelSlack({
      membersSyncClaimedAt: staleClaim,
      customEmojiSyncClaimedAt: staleClaim,
      // membersSyncedAt / customEmojiSyncedAt intentionally absent — the
      // queued tasks from the earlier claim never succeeded.
    });

    await slack.onChannelEnabled({ id: "C5", title: "retry-channel" } as never, undefined);

    expect(countCallbackCreates(create, "syncMembers")).toBe(1);
    expect(countCallbackCreates(create, "syncCustomEmoji")).toBe(1);
  });
});

describe("onChannelEnabled — saved-items backfill is a connection-level walk", () => {
  function makeBackfillSlack(storeInitial: Record<string, unknown> = {}) {
    const store = makeStore(storeInitial);
    const create = vi.fn(async (fn: { name?: string }) => ({
      token: "cb",
      name: fn?.name,
    }) as never);
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
    return { slack, store, create };
  }

  function countBackfillCreates(create: ReturnType<typeof vi.fn>): number {
    return create.mock.calls.filter(
      (call) => (call[0] as { name?: string })?.name === "backfillStars"
    ).length;
  }

  it("queues one backfill for a whole fan-out, not one per channel", async () => {
    // `stars.list` is workspace-wide and the backfill now saves every item it
    // finds, so queuing it per channel would re-walk the same list — and
    // re-save the same items — N times on every enable fan-out.
    const { slack, create } = makeBackfillSlack();

    for (const id of ["C1", "C2", "C3"]) {
      await slack.onChannelEnabled({ id, title: id } as never, undefined);
    }

    expect(countBackfillCreates(create)).toBe(1);
  });

  it("never re-queues once a full walk has completed", async () => {
    const { slack, create } = makeBackfillSlack({ stars_backfilled: true });

    await slack.onChannelEnabled({ id: "C9", title: "later" } as never, undefined);

    expect(countBackfillCreates(create)).toBe(0);
  });

  it("re-queues after a stale claim when the walk never completed", async () => {
    // A backfill that failed outright must not be suppressed forever: the
    // permanent flag is written only on a completed walk, and the claim that
    // covers the gap expires.
    const { slack, create } = makeBackfillSlack({
      starsBackfillClaimedAt: Date.now() - 6 * 60 * 1000,
    });

    await slack.onChannelEnabled({ id: "C9", title: "retry" } as never, undefined);

    expect(countBackfillCreates(create)).toBe(1);
  });
});

describe("backfillStars — every saved item, wherever it lives", () => {
  function makeStarBackfillSlack(storeInitial: Record<string, unknown> = {}) {
    const store = makeStore({ auth_actor_id: "actor-1", ...storeInitial });
    const tools = {
      store,
      integrations: { get: vi.fn(), markNeedsReauth: vi.fn() },
      network: { createWebhook: vi.fn() },
      files: {},
      callbacks: { create: vi.fn(async () => ({ token: "cb" }) as never) },
      tasks: { runTask: vi.fn(), scheduleTask: vi.fn() },
    };
    const slack = new Slack(
      "twist-instance-1" as never,
      { getTools: () => tools } as never
    ) as any;
    const saved: Array<[string, string]> = [];
    slack.saveStarredThread = vi.fn(
      async (_api: unknown, channelId: string, threadTs: string) => {
        saved.push([channelId, threadTs]);
      }
    );
    return { slack, store, saved };
  }

  const starItem = (channel: string, ts: string) => ({
    type: "message",
    channel,
    message: { ts },
  });

  it("backfills saved items in a direct conversation, not only the enabled channel", async () => {
    // The old channel filter meant a DM's saved messages were never
    // backfilled at all: a DM id never passes through onChannelEnabled.
    const { slack, saved, store } = makeStarBackfillSlack({
      dm_channels: ["D1"],
      dm_conversations: { D1: { user: "U2" } },
    });
    const listStars = vi.fn().mockResolvedValue({
      items: [starItem("C1", "100.0"), starItem("D1", "200.0")],
      nextCursor: undefined,
    });
    vi.spyOn(slack, "getApi").mockResolvedValue({ listStars });

    await slack.backfillStars("C1", null);

    expect(saved).toEqual([
      ["C1", "100.0"],
      ["D1", "200.0"],
    ]);
    // A DM star needs the anchor, or unstarring it from Plot later would
    // target wherever the conversation head has since moved to.
    expect(store.map.get("star_anchor:D1")).toBe("200.0");
    expect(store.map.get("starred:D1:200.0")).toBe(true);
    // The walk completed, so it never needs to run again.
    expect(store.map.get("stars_backfilled")).toBe(true);
  });

  it("does not mark the walk complete when it stops on a rate limit", async () => {
    const { slack, store } = makeStarBackfillSlack();
    const listStars = vi
      .fn()
      .mockRejectedValue(new SlackRateLimitedError("stars.list", 1000));
    vi.spyOn(slack, "getApi").mockResolvedValue({ listStars });
    slack.rescheduleAt = vi.fn(async () => {});

    await slack.backfillStars("C1", null);

    expect(store.map.has("stars_backfilled")).toBe(false);
  });
});

describe("onChannelDisabled — every keyed chain is torn down", () => {
  it("cancels the recurring chains and drains keyed to the channel", async () => {
    // A chain left running fires daily forever and calls
    // integrations.get(channelId), whose migration fallback rewrites the
    // channel config as enabled — so a leak resurrects the channel.
    const store = makeStore({ "starred:C1:100.0": true });
    const cancelScheduledTask = vi.fn(async (_key: string) => {});
    const tools = {
      store,
      integrations: { get: vi.fn() },
      network: { createWebhook: vi.fn() },
      files: {},
      callbacks: { create: vi.fn() },
      tasks: { cancelScheduledTask },
    };
    const slack = new Slack(
      "twist-instance-1" as never,
      { getTools: () => tools } as never
    );

    await slack.onChannelDisabled({ id: "C1", title: "general" } as never);

    // `cancelDrain(key)` cancels the drain's own task, which the SDK names
    // with a reserved prefix — both teardown kinds land here.
    const cancelled = cancelScheduledTask.mock.calls.map((c) => c[0]);
    expect(cancelled).toEqual(
      expect.arrayContaining([
        "members-sync:C1",
        "custom-emoji-sync:C1",
        "user-groups-sync:C1",
        "dm-channels-sync:C1",
        "__drain__:incremental-sync:C1",
        "__drain__:reaction-refresh:C1",
        "__drain__:subscribed-thread:C1",
      ])
    );
  });

  it("cancels a pending rate-limit retry for a reaction on this channel", async () => {
    // A reaction's scope check that hit a Slack rate limit schedules a
    // one-shot retry keyed per message (unlike the chains above, which each
    // have one fixed key for the whole channel) and records a listable
    // marker so this can find it. A retry left running re-enters the same
    // token lookup those chains do, with the same resurrection risk.
    const store = makeStore({
      "reaction-scope-pending:C1:100.0": true,
      "reaction-scope-pending:C1:200.0": true,
      // A different channel's pending retry must be left alone.
      "reaction-scope-pending:C2:300.0": true,
    });
    const cancelScheduledTask = vi.fn(async (_key: string) => {});
    const tools = {
      store,
      integrations: { get: vi.fn() },
      network: { createWebhook: vi.fn() },
      files: {},
      callbacks: { create: vi.fn() },
      tasks: { cancelScheduledTask },
    };
    const slack = new Slack(
      "twist-instance-1" as never,
      { getTools: () => tools } as never
    );

    await slack.onChannelDisabled({ id: "C1", title: "general" } as never);

    const cancelled = cancelScheduledTask.mock.calls.map((c) => c[0]);
    expect(cancelled).toEqual(
      expect.arrayContaining([
        "reaction-scope:C1:100.0",
        "reaction-scope:C1:200.0",
      ])
    );
    expect(cancelled).not.toContain("reaction-scope:C2:300.0");
    expect(store.map.has("reaction-scope-pending:C1:100.0")).toBe(false);
    expect(store.map.has("reaction-scope-pending:C1:200.0")).toBe(false);
    // The other channel's marker is untouched.
    expect(store.map.get("reaction-scope-pending:C2:300.0")).toBe(true);
  });
});

describe("onSlackWebhook — DM/MPIM message routing", () => {
  function makeDMWebhookSlack(opts: {
    store: ReturnType<typeof makeStore>;
  }) {
    const scheduleDrain = vi.fn(async () => {});
    const tools = {
      store: opts.store,
      integrations: { get: vi.fn() },
      network: { createWebhook: vi.fn() },
      files: {},
      callbacks: { create: vi.fn(async () => ({ token: "cb" }) as never) },
      tasks: { runTask: vi.fn(async () => "task-token"), scheduleRecurring: vi.fn(async () => {}) },
    };
    const slack = new Slack("twist-instance-1" as never, { getTools: () => tools } as never);
    vi.spyOn(
      slack as unknown as { scheduleDrain: (...a: unknown[]) => Promise<void> },
      "scheduleDrain"
    ).mockImplementation(scheduleDrain);
    return { slack, scheduleDrain };
  }

  it("starts incremental sync for a message on a known DM channel", async () => {
    const store = makeStore({ dm_channels: ["D1"] });
    const { slack, scheduleDrain } = makeDMWebhookSlack({ store });

    await slack.onSlackWebhook(
      { body: { event: { type: "message", channel: "D1" } } } as never,
      Slack.DM_WEBHOOK_SENTINEL
    );

    expect(scheduleDrain).toHaveBeenCalledWith(
      "incremental-sync:D1",
      expect.anything(),
      expect.objectContaining({ handlerArgs: ["D1"] })
    );
  });

  it("ignores a message on a channel not in the known DM set", async () => {
    const store = makeStore({ dm_channels: ["D1"] });
    const { slack, scheduleDrain } = makeDMWebhookSlack({ store });

    await slack.onSlackWebhook(
      { body: { event: { type: "message", channel: "G-not-a-known-dm" } } } as never,
      Slack.DM_WEBHOOK_SENTINEL
    );

    expect(scheduleDrain).not.toHaveBeenCalled();
  });

  it("ignores a channel message delivered under a channel id rather than a sentinel", async () => {
    // Nothing registers a callback per channel any more, so a message is
    // never routed by matching the channel a callback was registered for.
    // A stale per-channel registration from an older deploy must not drag a
    // whole channel back into sync.
    const store = makeStore({ dm_channels: ["C123"] });
    const { slack, scheduleDrain } = makeDMWebhookSlack({ store });

    await slack.onSlackWebhook(
      { body: { event: { type: "message", channel: "C123" } } } as never,
      "C123"
    );

    expect(scheduleDrain).not.toHaveBeenCalled();
  });
});

describe("onSlackWebhook — reaction events", () => {
  const req = (event: unknown) => ({ body: { event } }) as never;

  function makeReactionSlack(initial: Record<string, unknown>) {
    const store = makeStore(initial);
    const integrationsGet = vi.fn();
    const tools = {
      store,
      integrations: { get: integrationsGet },
      network: {},
      files: {},
    };
    const slack = new Slack(
      "twist-instance-1" as never,
      { getTools: () => tools } as never
    );
    const scheduleDrain = vi.fn(async () => {});
    vi.spyOn(
      slack as unknown as { scheduleDrain: (...a: unknown[]) => Promise<void> },
      "scheduleDrain"
    ).mockImplementation(scheduleDrain);
    return { slack, scheduleDrain, integrationsGet, store };
  }

  it("routes reaction_added on a subscribed thread through a coalesced per-channel drain", async () => {
    // conversations.history/replies are 1 rpm for non-Marketplace apps, so
    // refreshing inline in the webhook handler meant reaction bursts were
    // rate limited and silently dropped (Slack got a 200 and never
    // redelivers). The event must instead be recorded in a durable drain.
    const { slack, scheduleDrain } = makeReactionSlack({
      "sync_thread:C123:1784217892.588139": true,
    });

    await slack.onSlackWebhook(
      req({
        type: "reaction_added",
        item: { type: "message", channel: "C123", ts: "1784217892.588139" },
      }),
      Slack.MENTION_WEBHOOK_SENTINEL
    );

    expect(scheduleDrain).toHaveBeenCalledWith(
      "reaction-refresh:C123",
      expect.anything(),
      expect.objectContaining({
        ids: ["1784217892.588139"],
        handlerArgs: ["C123"],
      })
    );
  });

  it("routes a reaction in a direct conversation", async () => {
    const { slack, scheduleDrain } = makeReactionSlack({ dm_channels: ["D1"] });

    await slack.onSlackWebhook(
      req({
        type: "reaction_added",
        item: { type: "message", channel: "D1", ts: "1.000" },
      }),
      Slack.DM_WEBHOOK_SENTINEL
    );

    expect(scheduleDrain).toHaveBeenCalledWith(
      "reaction-refresh:D1",
      expect.anything(),
      expect.objectContaining({ ids: ["1.000"], handlerArgs: ["D1"] })
    );
  });

  it("ignores a reaction on a conversation nothing is synced from", async () => {
    // Reactions from the whole workspace reach this handler. A channel with
    // no subscribed thread and no direct conversation has nothing in Plot to
    // refresh, so scheduling a drain would only burn a rate-limited call.
    const { slack, scheduleDrain } = makeReactionSlack({});

    await slack.onSlackWebhook(
      req({
        type: "reaction_added",
        item: { type: "message", channel: "C123", ts: "1.000" },
      }),
      Slack.MENTION_WEBHOOK_SENTINEL
    );

    expect(scheduleDrain).not.toHaveBeenCalled();
  });

  it("does not resolve a token or a parent for a channel with no subscribed thread", async () => {
    // The parent lookup costs a `conversations.history` call, limited to
    // 1 rpm — spending one per reaction anywhere in the workspace would keep
    // the connection permanently rate limited for no benefit.
    const { slack, scheduleDrain, integrationsGet } = makeReactionSlack({});
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
    try {
      await slack.onSlackWebhook(
        req({
          type: "reaction_added",
          item: { type: "message", channel: "C123", ts: "1.000" },
        }),
        Slack.MENTION_WEBHOOK_SENTINEL
      );
    } finally {
      vi.unstubAllGlobals();
    }

    expect(integrationsGet).not.toHaveBeenCalled();
    expect(fetchMock).not.toHaveBeenCalled();
    expect(scheduleDrain).not.toHaveBeenCalled();
  });

  it("resolves the parent so a reaction on a reply reaches its subscribed thread", async () => {
    // A subscription is recorded against the thread PARENT, but the reaction
    // event carries only the reacted message's own ts. Without resolving the
    // parent, every reaction on a reply would be dropped.
    const { slack, scheduleDrain } = makeReactionSlack({
      "sync_thread:C123:100.000": true,
    });
    const api = {
      getConversationHistory: vi.fn(async () => ({
        messages: [{ ts: "101.000", thread_ts: "100.000" }] as SlackMessage[],
        hasMore: false,
      })),
    };
    vi.spyOn(
      slack as unknown as { getApi: (c: string) => Promise<unknown> },
      "getApi"
    ).mockResolvedValue(api);

    await slack.onSlackWebhook(
      req({
        type: "reaction_added",
        item: { type: "message", channel: "C123", ts: "101.000" },
      }),
      Slack.MENTION_WEBHOOK_SENTINEL
    );

    expect(api.getConversationHistory).toHaveBeenCalled();
    expect(scheduleDrain).toHaveBeenCalledWith(
      "reaction-refresh:C123",
      expect.anything(),
      expect.objectContaining({ ids: ["101.000"] })
    );
  });

  it("retries the scope decision instead of dropping it when the parent lookup is rate limited", async () => {
    // `conversations.history` is 1 rpm, so a busy channel hits this
    // routinely. Slack never redelivers an acked event, so a swallowed rate
    // limit loses the reaction for good — and we cannot just queue the drain,
    // because without the parent we cannot tell whether the thread is
    // subscribed and syncing an unsubscribed one puts a thread in Plot the
    // user never asked for.
    const { slack, scheduleDrain } = makeReactionSlack({
      "sync_thread:C123:100.000": true,
    });
    const api = {
      getConversationHistory: vi.fn(async () => {
        throw new SlackRateLimitedError("conversations.history", 30_000);
      }),
    };
    vi.spyOn(
      slack as unknown as { getApi: (c: string) => Promise<unknown> },
      "getApi"
    ).mockResolvedValue(api);
    const scheduleTask = vi.fn(async () => {});
    vi.spyOn(
      slack as unknown as {
        scheduleTask: (...a: unknown[]) => Promise<void>;
      },
      "scheduleTask"
    ).mockImplementation(scheduleTask);
    vi.spyOn(
      slack as unknown as { callback: (...a: unknown[]) => Promise<unknown> },
      "callback"
    ).mockResolvedValue({ token: "cb" });

    await slack.onSlackWebhook(
      req({
        type: "reaction_added",
        item: { type: "message", channel: "C123", ts: "101.000" },
      }),
      Slack.MENTION_WEBHOOK_SENTINEL
    );

    expect(scheduleDrain).not.toHaveBeenCalled();
    expect(scheduleTask).toHaveBeenCalledWith(
      "reaction-scope:C123:101.000",
      expect.anything(),
      expect.objectContaining({ runAt: expect.any(Date) })
    );
  });

  it("rethrows an unexpected failure of the scope decision", async () => {
    // Every reaction in the workspace reaches this path now that channel
    // gating is gone, so a swallowed bug here would be silent and constant.
    const { slack } = makeReactionSlack({ "sync_thread:C123:100.000": true });
    let calls = 0;
    vi.spyOn(
      slack as unknown as { getApi: (c: string) => Promise<unknown> },
      "getApi"
    ).mockResolvedValue({
      getConversationHistory: vi.fn(async () => ({
        messages: [] as SlackMessage[],
        hasMore: false,
      })),
    });
    vi.spyOn(
      slack as unknown as {
        isSubscribedThread: (...a: unknown[]) => Promise<boolean>;
      },
      "isSubscribedThread"
    ).mockImplementation(async () => {
      // The cheap pre-check answers "not subscribed"; the lookup that follows
      // the parent resolution then fails unexpectedly.
      if (calls++ === 0) return false;
      throw new Error("store unavailable");
    });

    await expect(
      slack.onSlackWebhook(
        req({
          type: "reaction_added",
          item: { type: "message", channel: "C123", ts: "101.000" },
        }),
        Slack.MENTION_WEBHOOK_SENTINEL
      )
    ).rejects.toThrow("store unavailable");
  });
});

describe("drainReactionRefresh", () => {
  function makeDrainSlack(initial: Record<string, unknown> = {}) {
    const store = makeStore(initial);
    const markNeedsReauth = vi.fn(async () => {});
    const tools = {
      store,
      integrations: { get: vi.fn(), markNeedsReauth },
      network: {},
      files: {},
    };
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const slack = new Slack(
      "twist-instance-1" as never,
      { getTools: () => tools } as never
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ) as any;
    const api = {
      getConversationHistory: vi.fn(async (_c: string, _cur?: string, oldest?: string) => ({
        messages: [{ ts: oldest }] as SlackMessage[],
        hasMore: false,
      })),
    };
    vi.spyOn(slack, "getApi").mockResolvedValue(api);
    const refresh = vi
      .spyOn(slack, "refreshSlackThread")
      .mockResolvedValue(undefined);
    return { slack, api, refresh, markNeedsReauth };
  }

  it("resolves each reacted message's parent and refreshes it once per parent", async () => {
    const { slack, api, refresh } = makeDrainSlack();
    api.getConversationHistory.mockImplementation(async (_c, _cur, oldest) => ({
      messages: [{ ts: oldest, thread_ts: "100.000" }] as SlackMessage[],
      hasMore: false,
    }));

    const result = await slack.drainReactionRefresh(
      ["101.000", "102.000"],
      "C123"
    );

    expect(result).toBeUndefined();
    expect(refresh).toHaveBeenCalledTimes(1);
    expect(refresh).toHaveBeenCalledWith(expect.anything(), "C123", "100.000");
  });

  it("returns rate-limited ids for retry instead of dropping them", async () => {
    const { slack, api, refresh } = makeDrainSlack();
    api.getConversationHistory.mockRejectedValue(
      new SlackRateLimitedError("conversations.history", 60_000)
    );

    const result = await slack.drainReactionRefresh(
      ["101.000", "102.000"],
      "C123"
    );

    expect(result).toEqual({ retry: ["101.000", "102.000"] });
    expect(refresh).not.toHaveBeenCalled();
  });

  it("retries only the remaining ids when rate limited mid-pass", async () => {
    const { slack, refresh } = makeDrainSlack();
    refresh
      .mockResolvedValueOnce(undefined)
      .mockRejectedValueOnce(
        new SlackRateLimitedError("conversations.replies", 60_000)
      );

    const result = await slack.drainReactionRefresh(
      ["101.000", "102.000"],
      "C123"
    );

    expect(result).toEqual({ retry: ["102.000"] });
  });

  it("skips permanently failed ids and continues the pass", async () => {
    const { slack, refresh } = makeDrainSlack();
    refresh
      .mockRejectedValueOnce(
        new SlackPermanentError("conversations.replies", "thread_not_found")
      )
      .mockResolvedValueOnce(undefined);

    const result = await slack.drainReactionRefresh(
      ["101.000", "102.000"],
      "C123"
    );

    expect(result).toBeUndefined();
    expect(refresh).toHaveBeenCalledTimes(2);
  });

});

describe("handleStarEvent — rate limited", () => {
  it("schedules a keyed retry instead of dropping the star", async () => {
    const store = makeStore({ token_channel_C123: true, auth_actor_id: "actor-1" });
    const scheduleTask = vi.fn(async () => "cancel-token");
    const tools = {
      store,
      callbacks: { create: vi.fn(async () => ({ token: "cb" }) as never) },
      tasks: { scheduleTask, runTask: vi.fn(async () => {}) },
      integrations: { get: vi.fn() },
      network: {},
      files: {},
    };
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const slack = new Slack(
      "twist-instance-1" as never,
      { getTools: () => tools } as never
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ) as any;
    vi.spyOn(slack, "getApi").mockResolvedValue({});
    vi.spyOn(slack, "saveStarredThread").mockRejectedValue(
      new SlackRateLimitedError("conversations.replies", 60_000)
    );

    await slack.onSlackWebhook(
      {
        body: {
          event: {
            type: "star_added",
            item: { type: "message", channel: "C123", message: { ts: "111.000" } },
          },
        },
      } as never,
      "C123"
    );

    expect(scheduleTask).toHaveBeenCalledTimes(1);
    const [key, , options] = scheduleTask.mock.calls[0] as unknown as [
      string,
      unknown,
      { runAt: Date },
    ];
    expect(key).toBe("star-apply:C123:111.000");
    expect(options.runAt.getTime()).toBeGreaterThan(Date.now());
    // Starred state must stay unrecorded until the retry lands, so the
    // rescheduled apply isn't skipped as an echo.
    expect(store.map.has("starred:C123:111.000")).toBe(false);
  });

  it("rethrows an unexpected failure and leaves the state unrecorded", async () => {
    // Every star in the workspace reaches this path now that channel gating
    // is gone. Swallowing an unexpected failure would both hide the bug and
    // record a state the apply never actually reached.
    const store = makeStore({ token_channel_C123: true, auth_actor_id: "actor-1" });
    const tools = {
      store,
      callbacks: { create: vi.fn(async () => ({ token: "cb" }) as never) },
      tasks: { scheduleTask: vi.fn(), runTask: vi.fn(async () => {}) },
      integrations: { get: vi.fn(), markNeedsReauth: vi.fn() },
      network: {},
      files: {},
    };
    const slack = new Slack(
      "twist-instance-1" as never,
      { getTools: () => tools } as never
    ) as any;
    vi.spyOn(slack, "getApi").mockResolvedValue({});
    vi.spyOn(slack, "saveStarredThread").mockRejectedValue(
      new TypeError("cannot read properties of undefined")
    );

    await expect(
      slack.applyStarEvent("C123", "111.000", true)
    ).rejects.toThrow("cannot read properties of undefined");
    expect(store.map.has("starred:C123:111.000")).toBe(false);
  });

  it("records the state for a permanent Slack error so duplicates stop re-failing", async () => {
    // A deleted message will never apply. Recording short-circuits the
    // duplicate events, and reauth is NOT flagged — the grant is fine.
    const store = makeStore({ token_channel_C123: true, auth_actor_id: "actor-1" });
    const markNeedsReauth = vi.fn();
    const tools = {
      store,
      callbacks: { create: vi.fn(async () => ({ token: "cb" }) as never) },
      tasks: { scheduleTask: vi.fn(), runTask: vi.fn(async () => {}) },
      integrations: { get: vi.fn(), markNeedsReauth },
      network: {},
      files: {},
    };
    const slack = new Slack(
      "twist-instance-1" as never,
      { getTools: () => tools } as never
    ) as any;
    vi.spyOn(slack, "getApi").mockResolvedValue({});
    vi.spyOn(slack, "saveStarredThread").mockRejectedValue(
      new SlackPermanentError("conversations.replies", "thread_not_found")
    );

    await slack.applyStarEvent("C123", "111.000", true);

    expect(markNeedsReauth).not.toHaveBeenCalled();
    expect(store.map.get("starred:C123:111.000")).toBe(true);
  });
});

describe("createDirectMessage — proactively registers the DM channel", () => {
  it("adds the opened conversation id to the known dm_channels set", async () => {
    const store = makeStore({ token_channel_C1: true, dm_channels: ["D-existing"] });
    const integrationsGet = vi.fn().mockResolvedValue({ token: "xoxp-test" });
    const tools = {
      store,
      integrations: { get: integrationsGet },
      network: { createWebhook: vi.fn() },
      files: {},
    };
    const slack = new Slack("twist-instance-1" as never, { getTools: () => tools } as never);

    const api = {
      openConversation: vi.fn().mockResolvedValue("D-new"),
      postMessage: vi.fn().mockResolvedValue({ ts: "111.000", text: "hi" }),
    };
    vi.spyOn(
      slack as unknown as { getWorkspaceApi: (c: string) => Promise<unknown> },
      "getWorkspaceApi"
    ).mockResolvedValue(api);

    const draft = {
      type: "dm",
      channelId: "C1",
      title: "hi",
      noteContent: "hi",
      recipients: [{ externalAccountId: "U2" }],
    };
    await slack.onCreateLink(draft as never);

    expect(store.map.get("dm_channels")).toEqual(
      expect.arrayContaining(["D-existing", "D-new"])
    );
  });

  it("records the recipient so the new conversation keys on the person", async () => {
    // A 1:1 whose counterparty is unknown keys on the conversation instead of
    // the person — a different, permanent link for the same chat, which would
    // then never merge with the one the daily roster refresh produces.
    const store = makeStore({ token_channel_C1: true });
    const integrationsGet = vi.fn().mockResolvedValue({ token: "xoxp-test" });
    const tools = {
      store,
      integrations: { get: integrationsGet },
      network: { createWebhook: vi.fn() },
      files: {},
    };
    const slack = new Slack("twist-instance-1" as never, { getTools: () => tools } as never);

    const api = {
      openConversation: vi.fn().mockResolvedValue("D-new"),
      postMessage: vi.fn().mockResolvedValue({ ts: "111.000", text: "hi" }),
    };
    vi.spyOn(
      slack as unknown as { getWorkspaceApi: (c: string) => Promise<unknown> },
      "getWorkspaceApi"
    ).mockResolvedValue(api);

    await slack.onCreateLink({
      type: "dm",
      channelId: "C1",
      title: "hi",
      noteContent: "hi",
      recipients: [{ externalAccountId: "U2" }],
    } as never);

    expect(store.map.get("dm_conversations")).toEqual({
      "D-new": { user: "U2" },
    });
  });

  it("keys the composed conversation exactly as the same conversation arriving from Slack", async () => {
    // A direct conversation has ONE permanent link however it started. If the
    // composed link is keyed differently, starting a chat from Plot and then
    // receiving a reply leaves two permanent threads for one conversation,
    // forever — nothing ever reconciles them.
    const store = makeStore({ token_channel_C1: true });
    const tools = {
      store,
      integrations: { get: vi.fn().mockResolvedValue({ token: "xoxp-test" }) },
      network: { createWebhook: vi.fn() },
      files: {},
    };
    const slack = new Slack("twist-instance-1" as never, { getTools: () => tools } as never);
    vi.spyOn(
      slack as unknown as { getWorkspaceApi: (c: string) => Promise<unknown> },
      "getWorkspaceApi"
    ).mockResolvedValue({
      openConversation: vi.fn().mockResolvedValue("D-new"),
      postMessage: vi.fn().mockResolvedValue({ ts: "111.000", text: "hi" }),
    });

    const composed = await slack.onCreateLink({
      type: "dm",
      channelId: "C1",
      title: "hi",
      noteContent: "hi",
      recipients: [{ externalAccountId: "U2" }],
    } as never);

    // What the sync path produces for the very same conversation.
    const synced = assembleSlackDmLink({
      channelId: "D-new",
      counterpartyUserId: "U2",
      messages: [
        { type: "message", ts: "111.000", user: "U2", text: "hi" },
      ] as SlackMessage[],
      initialSync: false,
    });

    expect(composed?.source).toBe(synced?.source);
    expect(composed?.sources).toEqual(synced?.sources);
    expect(composed?.meta?.direct).toBe(true);
  });

  it("records a multi-recipient conversation with no single counterparty", async () => {
    const store = makeStore({ token_channel_C1: true });
    const tools = {
      store,
      integrations: { get: vi.fn().mockResolvedValue({ token: "xoxp-test" }) },
      network: { createWebhook: vi.fn() },
      files: {},
    };
    const slack = new Slack("twist-instance-1" as never, { getTools: () => tools } as never);

    vi.spyOn(
      slack as unknown as { getWorkspaceApi: (c: string) => Promise<unknown> },
      "getWorkspaceApi"
    ).mockResolvedValue({
      openConversation: vi.fn().mockResolvedValue("G-new"),
      postMessage: vi.fn().mockResolvedValue({ ts: "111.000", text: "hi" }),
    });

    await slack.onCreateLink({
      type: "dm",
      channelId: "C1",
      title: "hi",
      noteContent: "hi",
      recipients: [{ externalAccountId: "U2" }, { externalAccountId: "U3" }],
    } as never);

    expect(store.map.get("dm_conversations")).toEqual({ "G-new": {} });
  });
});

describe("conversation link shape", () => {
  function makeShapeSlack(initial: Record<string, unknown> = {}) {
    const store = makeStore(initial);
    const saveLink = vi.fn().mockResolvedValue("thread-1");
    const tools = {
      store,
      integrations: {
        get: vi.fn().mockResolvedValue({
          token: "xoxp-1",
          provider: { team_id: "T0" },
        }),
        saveLink,
      },
      network: { createWebhook: vi.fn() },
      files: {},
    };
    const slack = new Slack(
      "twist-instance-1" as never,
      { getTools: () => tools } as never
    ) as any;
    vi.spyOn(slack, "getApi").mockResolvedValue({
      getUser: vi.fn().mockResolvedValue(null),
    });
    return { slack, saveLink, store };
  }

  const message = (ts: string, text: string): SlackMessage =>
    ({ type: "message", ts, user: "U2", text }) as SlackMessage;

  const directStore = {
    dm_channels: ["D1"],
    dm_conversations: { D1: { user: "U2" } },
  };

  it("saves a direct conversation as one permanent link keyed on the other person", async () => {
    const { slack, saveLink } = makeShapeSlack(directStore);

    // Two separate Slack "threads" in the same conversation.
    await slack.processMessageThreads(
      [[message("100.0", "hi")], [message("101.0", "still me")]],
      "D1",
      false
    );

    expect(saveLink).toHaveBeenCalledTimes(1);
    const link = saveLink.mock.calls[0][0];
    expect(link.type).toBe("dm");
    expect(link.source).toBe("slack:person:U2");
    expect(link.meta.direct).toBe(true);
    expect(link.notes.map((n: { key: string }) => n.key)).toEqual([
      "100.0",
      "101.0",
    ]);
  });

  it("keeps Slack's own thread structure outside a direct conversation", async () => {
    const { slack, saveLink } = makeShapeSlack();

    await slack.processMessageThreads(
      [[message("100.0", "hi")], [message("101.0", "unrelated")]],
      "C1",
      false
    );

    expect(saveLink).toHaveBeenCalledTimes(2);
    expect(saveLink.mock.calls[0][0].type).toBe("thread");
  });

  it("refreshes a direct conversation onto the same link rather than a second thread", async () => {
    // Re-reading a thread is how a reaction reaches an already-synced
    // conversation. Building a channel-shaped link here would leave the same
    // direct conversation showing up twice in Plot.
    const { slack, saveLink } = makeShapeSlack(directStore);
    const api = {
      getThread: vi.fn().mockResolvedValue([message("100.0", "hi")]),
      getUser: vi.fn().mockResolvedValue(null),
    };

    await slack.refreshSlackThread(api, "D1", "100.0");

    const link = saveLink.mock.calls[0][0];
    expect(link.type).toBe("dm");
    expect(link.source).toBe("slack:person:U2");
  });

  it("saves a message saved in a direct conversation onto that conversation's link", async () => {
    const { slack, saveLink } = makeShapeSlack(directStore);
    const api = {
      getThread: vi.fn().mockResolvedValue([message("100.0", "hi")]),
      getUser: vi.fn().mockResolvedValue(null),
    };

    await slack.saveStarredThread(api, "D1", "100.0");

    const link = saveLink.mock.calls[0][0];
    expect(link.type).toBe("dm");
    expect(link.todo).toBe(true);
  });

  it("drops a message Plot itself sent out of a direct conversation", async () => {
    // The echo guard keys on the note key for transformed notes; a raw Slack
    // message carries the same value as its `ts`. Without matching on `ts`,
    // every message Plot sends into a DM comes back as a duplicate note.
    const { slack, saveLink, store } = makeShapeSlack({
      ...directStore,
      "sent:100.0": true,
    });

    await slack.processMessageThreads(
      [[message("100.0", "echo"), message("101.0", "real")]],
      "D1",
      false
    );

    const link = saveLink.mock.calls[0][0];
    expect(link.notes.map((n: { key: string }) => n.key)).toEqual(["101.0"]);
    // Cleared on first read so a later genuine edit re-syncs.
    expect(store.map.has("sent:100.0")).toBe(false);
  });

  it("leaves the sent marker alone when a saved conversation is re-read", async () => {
    // Saving a message re-reads a conversation Plot may itself have written
    // into. The marker is spent on first read, so consuming it here would let
    // the real inbound echo through afterwards as a duplicate note.
    const { slack, store } = makeShapeSlack({
      ...directStore,
      "sent:100.0": true,
    });
    const api = {
      getThread: vi.fn().mockResolvedValue([message("100.0", "hi")]),
      getUser: vi.fn().mockResolvedValue(null),
    };

    await slack.saveStarredThread(api, "D1", "100.0");

    expect(store.map.get("sent:100.0")).toBe(true);
  });

  it("does not rewrite a direct conversation's head when refreshing an old message", async () => {
    // A reaction can name a message of any age. Rebuilding the link from just
    // that thread would upsert the preview, the open-in-Slack anchor and the
    // start date from an arbitrary old message — so reacting to a month-old
    // message would regress the whole conversation's preview.
    const { slack, saveLink } = makeShapeSlack({
      ...directStore,
      // The conversation already has a head to preserve.
      "dm_head:D1": true,
    });
    const api = {
      getThread: vi.fn().mockResolvedValue([message("100.0", "ancient")]),
      getUser: vi.fn().mockResolvedValue(null),
    };

    await slack.refreshSlackThread(api, "D1", "100.0");

    const link = saveLink.mock.calls[0][0];
    expect(link.preview).toBeUndefined();
    expect(link.sourceUrl).toBeUndefined();
    expect(link.created).toBeUndefined();
    // A to-do star on this link must not be redirected onto a month-old
    // message just because a reaction happened to name it.
    expect(link.meta.threadTs).toBeUndefined();
    // The notes themselves still upsert — that is the point of the refresh.
    expect(link.notes.map((n: { key: string }) => n.key)).toEqual(["100.0"]);
  });

  it("does advance the head when the messages are the live window", async () => {
    const { slack, saveLink, store } = makeShapeSlack(directStore);

    await slack.processMessageThreads([[message("100.0", "latest")]], "D1", false);

    const link = saveLink.mock.calls[0][0];
    expect(link.preview).toBe("latest");
    expect(link.sourceUrl).toContain("message_ts=100.0");
    expect(link.created).toBeInstanceOf(Date);
    // onThreadToDo stars whichever message meta.threadTs names — this must
    // track the newest message so a to-do star lands on it, matching what
    // sourceUrl already anchors on.
    expect(link.meta.threadTs).toBe("100.0");
    // ...and records that there is now a head, so a later reaction or save on
    // an old message knows it has something to preserve.
    expect(store.map.get("dm_head:D1")).toBe(true);
  });

  it("gives a direct conversation a head when an old message CREATES it", async () => {
    // Saving or reacting to an old message in a conversation Plot has never
    // synced is a CREATE, not an update: there is no stored preview, anchor
    // or start date to protect, so omitting them leaves a permanently
    // previewless thread with no way to open it in Slack until the next
    // inbound message happens to arrive.
    const { slack, saveLink } = makeShapeSlack(directStore); // no dm_head:D1
    const api = {
      getThread: vi.fn().mockResolvedValue([message("100.0", "ancient")]),
      getUser: vi.fn().mockResolvedValue(null),
    };

    await slack.refreshSlackThread(api, "D1", "100.0");

    const link = saveLink.mock.calls[0][0];
    expect(link.preview).toBe("ancient");
    expect(link.sourceUrl).toContain("message_ts=100.0");
    expect(link.created).toBeInstanceOf(Date);
    expect(link.meta.threadTs).toBe("100.0");
  });

  it("protects a conversation that an old message just created from a second old message rewinding it", async () => {
    // The first old-message save above is correctly a CREATE. But a second
    // old-message save on that same still-never-advanced conversation must
    // NOT repeat that create with a different message — that would rewind
    // what the first save just wrote, which is exactly what the stored-head
    // guard exists to prevent. It can only do that if the first save left
    // something behind recording that the conversation now has a head.
    const { slack, saveLink } = makeShapeSlack(directStore); // no dm_head:D1
    const firstApi = {
      getThread: vi
        .fn()
        .mockResolvedValue([message("100.0", "first old message")]),
      getUser: vi.fn().mockResolvedValue(null),
    };
    await slack.refreshSlackThread(firstApi, "D1", "100.0");
    expect(saveLink.mock.calls[0][0].preview).toBe("first old message");

    const secondApi = {
      getThread: vi
        .fn()
        .mockResolvedValue([message("50.0", "second, older message")]),
      getUser: vi.fn().mockResolvedValue(null),
    };
    await slack.refreshSlackThread(secondApi, "D1", "50.0");

    const secondLink = saveLink.mock.calls[1][0];
    expect(secondLink.preview).toBeUndefined();
    expect(secondLink.sourceUrl).toBeUndefined();
    expect(secondLink.created).toBeUndefined();
    expect(secondLink.meta.threadTs).toBeUndefined();
  });

  it("does not mark a whole direct conversation read when one message is saved", async () => {
    // A direct conversation is ONE permanent link. `initialSync` would put
    // `unread: false, archived: false` on it, so saving a single message in
    // Slack would mark every unread message in the conversation read — for
    // every user with access — and un-archive it.
    const { slack, saveLink } = makeShapeSlack(directStore);
    const api = {
      getThread: vi.fn().mockResolvedValue([message("100.0", "hi")]),
      getUser: vi.fn().mockResolvedValue(null),
    };

    await slack.saveStarredThread(api, "D1", "100.0");

    const link = saveLink.mock.calls[0][0];
    expect(link.unread).toBeUndefined();
    expect(link.archived).toBeUndefined();
    // The save itself still lands.
    expect(link.todo).toBe(true);
  });

  it("still marks a saved CHANNEL thread read, because the link is that thread", async () => {
    // The channel path keeps today's behaviour: the link IS the saved thread,
    // and saving something is not a reason to notify about it.
    const { slack, saveLink } = makeShapeSlack();
    const api = {
      getThread: vi.fn().mockResolvedValue([message("100.0", "hi")]),
      getUser: vi.fn().mockResolvedValue(null),
    };

    await slack.saveStarredThread(api, "C1", "100.0");

    const link = saveLink.mock.calls[0][0];
    expect(link.unread).toBe(false);
    expect(link.archived).toBe(false);
  });

  it("caches file to conversation before assembling the link", async () => {
    // downloadAttachment resolves an attachment's API token through this
    // mapping. A direct conversation returns early once its link is built, so
    // the mapping has to be written before that.
    const { slack } = makeShapeSlack(directStore);
    const withFile = {
      ...message("100.0", "see attached"),
      files: [{ id: "F1", name: "a.pdf" }],
    } as SlackMessage;

    await slack.processMessageThreads([[withFile]], "D1", false);

    expect((slack as any).tools.store.map.get("slack:file-channel:F1")).toBe(
      "D1"
    );
  });
});

describe("drainChannelSync", () => {
  it("syncs a direct conversation with no per-channel webhook state", async () => {
    // Direct conversations share one workspace-wide callback and never had a
    // registration of their own, so nothing per-channel can be required here.
    const store = makeStore({
      dm_channels: ["D1"],
      dm_conversations: { D1: { user: "U2" } },
    });
    const saveLink = vi.fn().mockResolvedValue("thread-1");
    const tools = {
      store,
      integrations: {
        get: vi.fn().mockResolvedValue({
          token: "xoxp-1",
          provider: { team_id: "T0" },
        }),
        saveLink,
      },
      network: {},
      files: {},
    };
    const slack = new Slack(
      "twist-instance-1" as never,
      { getTools: () => tools } as never
    ) as any;
    vi.spyOn(slack, "getApi").mockResolvedValue({
      getConversationHistory: vi.fn(async () => ({
        messages: [
          { type: "message", ts: "100.0", user: "U2", text: "hi" },
        ] as SlackMessage[],
        hasMore: false,
      })),
      getUser: vi.fn().mockResolvedValue(null),
    });

    await slack.drainChannelSync([], "D1");

    expect(saveLink).toHaveBeenCalledTimes(1);
    expect(saveLink.mock.calls[0][0].type).toBe("dm");
  });

  it("re-arms the drain past the retry window instead of dropping a rate-limited pass", async () => {
    // Slack never redelivers the message event that triggered the pass, so a
    // dropped pass loses the message outright.
    const store = makeStore({ dm_channels: ["D1"] });
    const tools = {
      store,
      integrations: { get: vi.fn(), markNeedsReauth: vi.fn(async () => {}) },
      network: {},
      files: {},
    };
    const slack = new Slack(
      "twist-instance-1" as never,
      { getTools: () => tools } as never
    ) as any;
    vi.spyOn(slack, "getApi").mockResolvedValue({
      getConversationHistory: vi.fn().mockRejectedValue(
        new SlackRateLimitedError("conversations.history", 60_000)
      ),
    });
    const scheduleDrain = vi.fn(async () => {});
    vi.spyOn(slack, "scheduleDrain").mockImplementation(scheduleDrain);

    await slack.drainChannelSync([], "D1");

    expect(scheduleDrain).toHaveBeenCalledWith(
      "incremental-sync:D1",
      expect.anything(),
      expect.objectContaining({ handlerArgs: ["D1"], delayMs: 60_000 })
    );
  });
});

describe("createChannelPost — posting is a statement of interest", () => {
  it("subscribes the thread it just posted so replies come back", async () => {
    // Channel content reaches Plot only through the subscription ledger or a
    // fresh mention. A reply to your own post carries neither, so without
    // this the conversation you started is the one you never hear back from.
    const store = makeStore({ token_channel_C1: true });
    const tools = {
      store,
      integrations: { get: vi.fn().mockResolvedValue({ token: "xoxp-test" }) },
      network: { createWebhook: vi.fn() },
      files: {},
    };
    const slack = new Slack("twist-instance-1" as never, { getTools: () => tools } as never);
    vi.spyOn(
      slack as unknown as { getApi: (c: string) => Promise<unknown> },
      "getApi"
    ).mockResolvedValue({
      postMessage: vi.fn().mockResolvedValue({ ts: "111.000", text: "hi" }),
    });

    await slack.onCreateLink({
      type: "thread",
      channelId: "C1",
      title: "hi",
      noteContent: "hi",
    } as never);

    expect(store.map.get("sync_thread:C1:111.000")).toBe(true);
  });
});

describe("applyStarEvent — clearing a to-do targets the link that carries it", () => {
  function makeStarSlack(initial: Record<string, unknown>) {
    const store = makeStore({ auth_actor_id: "actor-1", ...initial });
    const setThreadToDo = vi.fn().mockResolvedValue(undefined);
    const tools = {
      store,
      integrations: { get: vi.fn(), setThreadToDo },
      network: {},
      files: {},
      callbacks: { create: vi.fn(async () => ({ token: "cb" }) as never) },
      tasks: { scheduleTask: vi.fn(async () => "t"), runTask: vi.fn(async () => {}) },
    };
    const slack = new Slack(
      "twist-instance-1" as never,
      { getTools: () => tools } as never
    );
    return { slack, setThreadToDo };
  }

  it("clears a direct conversation's to-do by its permanent link", async () => {
    // Saving a message in a direct conversation marks that conversation's one
    // permanent link, keyed on the person. Addressing the message's own
    // canonical URL would name a source that does not exist, so the to-do
    // would sit there uncleared with nothing reporting a failure.
    const { slack, setThreadToDo } = makeStarSlack({
      dm_channels: ["D1"],
      dm_conversations: { D1: { user: "U2" } },
    });

    await slack.applyStarEvent("D1", "111.000", false);

    expect(setThreadToDo).toHaveBeenCalledWith(
      "slack:person:U2",
      "actor-1",
      false
    );
  });

  it("clears a channel thread's to-do by its message URL", async () => {
    const { slack, setThreadToDo } = makeStarSlack({});

    await slack.applyStarEvent("C1", "111.000", false);

    expect(setThreadToDo).toHaveBeenCalledWith(
      "https://slack.com/app_redirect?channel=C1&message_ts=111.000",
      "actor-1",
      false
    );
  });
});

describe("subscription ledger", () => {
  it("records a thread and reports it as subscribed", async () => {
    const store = makeStore();
    const slack = makeSlack({
      store,
      integrationsGet: vi.fn(),
      createWebhook: vi.fn(),
    });

    await (slack as any).subscribeThread("C1", "100.0");

    expect(store.map.get("sync_thread:C1:100.0")).toBe(true);
    expect(await (slack as any).isSubscribedThread("C1", "100.0")).toBe(true);
  });

  it("reports an unrecorded thread as not subscribed", async () => {
    const slack = makeSlack({
      store: makeStore(),
      integrationsGet: vi.fn(),
      createWebhook: vi.fn(),
    });

    expect(await (slack as any).isSubscribedThread("C1", "999.0")).toBe(false);
  });

  it("keeps the subscription when the thread is unstarred", async () => {
    // Seeded as already-subscribed AND currently starred, so the event below
    // is a genuine unstar (wasStarred true -> isStarred false) rather than an
    // echo the `wasStarred === isStarred` guard would short-circuit before
    // ever reaching application logic. `item.message.ts` (not a bare `ts` on
    // `item`) matches the real star-event shape `handleStarEvent` parses —
    // without it `parentTs` is undefined and the function returns at its
    // first guard, making this pass whether or not unstarring is wired
    // correctly.
    const store = makeStore({
      "sync_thread:C1:100.0": true,
      "starred:C1:100.0": true,
    });
    const slack = makeSlack({
      store,
      integrationsGet: vi.fn(),
      createWebhook: vi.fn(),
    });
    const applyStarEvent = vi.fn().mockResolvedValue(undefined);
    (slack as any).applyStarEvent = applyStarEvent;

    await (slack as any).handleStarEvent(
      { item: { type: "message", channel: "C1", message: { ts: "100.0" } } },
      false
    );

    // Confirms the event was actually processed as a real unstar (not
    // dropped as an echo), so the assertion below is meaningful.
    expect(applyStarEvent).toHaveBeenCalledWith("C1", "100.0", false);
    expect(await (slack as any).isSubscribedThread("C1", "100.0")).toBe(true);
  });

  it("subscribes a fresh thread when it is starred via handleStarEvent", async () => {
    // No `sync_thread:` and no `starred:` key seeded: this is a brand-new
    // thread being starred for the first time, so `wasStarred` (false) !==
    // isStarred (true) and the event is processed as a genuine star, not
    // dropped as an echo. This is the only test in this block that drives
    // the actual star->subscribe wiring in `handleStarEvent` end to end —
    // the other ledger tests either call `subscribeThread` directly or seed
    // the thread as already subscribed, so none of them would fail if the
    // `await this.subscribeThread(...)` call were deleted from
    // `handleStarEvent`.
    const store = makeStore();
    const slack = makeSlack({
      store,
      integrationsGet: vi.fn(),
      createWebhook: vi.fn(),
    });
    const applyStarEvent = vi.fn().mockResolvedValue(undefined);
    (slack as any).applyStarEvent = applyStarEvent;

    await (slack as any).handleStarEvent(
      { item: { type: "message", channel: "C1", message: { ts: "100.0" } } },
      true
    );

    expect(applyStarEvent).toHaveBeenCalledWith("C1", "100.0", true);
    expect(await (slack as any).isSubscribedThread("C1", "100.0")).toBe(true);
  });

  it("does not record a direct conversation in the per-thread ledger", async () => {
    // The ledger exists to decide which CHANNEL threads earn a place in Plot.
    // A direct conversation is synced in full and is one link rather than a
    // set of threads, so an entry here would be permanent noise.
    const store = makeStore({ dm_channels: ["D1"] });
    const slack = makeSlack({
      store,
      integrationsGet: vi.fn(),
      createWebhook: vi.fn(),
    });
    const applyStarEvent = vi.fn().mockResolvedValue(undefined);
    (slack as any).applyStarEvent = applyStarEvent;

    await (slack as any).handleStarEvent(
      { item: { type: "message", channel: "D1", message: { ts: "100.0" } } },
      true
    );

    // The save itself still applies — only the ledger write is skipped.
    expect(applyStarEvent).toHaveBeenCalledWith("D1", "100.0", true);
    expect(store.map.has("sync_thread:D1:100.0")).toBe(false);
  });
});

describe("cachedMentionContext", () => {
  it("builds the context from the cached identity and cached groups", async () => {
    const store = makeStore({
      slack_user_id: "U111",
      slack_user_groups: ["S222"],
    });
    const slack = makeSlack({
      store,
      integrationsGet: vi.fn(),
      createWebhook: vi.fn(),
    });

    const ctx = await (slack as any).cachedMentionContext();

    expect(ctx.userId).toBe("U111");
    expect([...ctx.userGroupIds]).toEqual(["S222"]);
  });

  it("treats a missing group cache as no groups", async () => {
    const slack = makeSlack({
      store: makeStore({ slack_user_id: "U111" }),
      integrationsGet: vi.fn(),
      createWebhook: vi.fn(),
    });

    const ctx = await (slack as any).cachedMentionContext();
    expect(ctx.userGroupIds.size).toBe(0);
  });
});

describe("channel message routing", () => {
  // `slack_user_id` pre-seeded: production only ever reaches
  // `handleChannelMessage` after `registerMentionWebhook` has cached it (the
  // mention webhook can't receive an event before it registers), so tests
  // seed the same precondition rather than resolving identity via
  // `integrations.get` — see `cachedMentionContext`.
  function setup(storeInit: Record<string, unknown> = {}) {
    const store = makeStore({ slack_user_id: "U111", ...storeInit });
    const integrationsGet = vi.fn().mockResolvedValue({
      token: "xoxp-1",
      scopes: ["usergroups:read"],
      provider: { authed_user_id: "U111" },
    });
    const slack = makeSlack({
      store,
      integrationsGet,
      createWebhook: vi.fn(),
    });
    const syncThread = vi.fn().mockResolvedValue(undefined);
    (slack as any).syncSubscribedThread = syncThread;
    return { slack, store, syncThread, integrationsGet };
  }

  it("syncs a channel message that mentions the user", async () => {
    const { slack, store, syncThread } = setup();

    await (slack as any).handleChannelMessage({
      channel: "C1",
      ts: "100.0",
      text: "hey <@U111>",
    });

    expect(syncThread).toHaveBeenCalledWith("C1", "100.0");
    expect(store.map.get("sync_thread:C1:100.0")).toBe(true);
  });

  it("subscribes the whole thread when the mention is in a reply", async () => {
    const { slack, store, syncThread } = setup();

    await (slack as any).handleChannelMessage({
      channel: "C1",
      ts: "101.0",
      thread_ts: "100.0",
      text: "<@U111> thoughts?",
    });

    expect(syncThread).toHaveBeenCalledWith("C1", "100.0");
    expect(store.map.get("sync_thread:C1:100.0")).toBe(true);
  });

  it("syncs a reply on an already-subscribed thread without a mention", async () => {
    const { slack, syncThread } = setup({ "sync_thread:C1:100.0": true });

    await (slack as any).handleChannelMessage({
      channel: "C1",
      ts: "102.0",
      thread_ts: "100.0",
      text: "no mention here",
    });

    expect(syncThread).toHaveBeenCalledWith("C1", "100.0");
  });

  it("ignores an unrelated channel message", async () => {
    const { slack, syncThread, store } = setup();

    await (slack as any).handleChannelMessage({
      channel: "C1",
      ts: "103.0",
      text: "just chatting",
    });

    expect(syncThread).not.toHaveBeenCalled();
    expect(store.map.has("sync_thread:C1:103.0")).toBe(false);
  });

  it("never resolves a Slack token while routing a channel message", async () => {
    // integrations.get(channelId) treats a deliberately-disabled channel's
    // falsy `enabled` as "never configured" and writes a migration fallback
    // that re-enables it (workers/api/src/twist/tools/integrations.ts
    // ~694-728). Calling it here, on every inbound channel message, would
    // silently re-enable channels the user disabled. Identity must come
    // only from the `slack_user_id` cache (see `cachedMentionContext`).
    const { slack, integrationsGet } = setup();

    await (slack as any).handleChannelMessage({
      channel: "C1",
      ts: "100.0",
      text: "hey <@U111>",
    });

    expect(integrationsGet).not.toHaveBeenCalled();
  });

  it("ignores a direct-message event even when it mentions the user", async () => {
    // Both webhook sentinels are registered from the same authorization
    // and therefore carry identical scopes, so the platform's scope-based
    // fan-out delivers `im`/`mpim` message events to the mention-sentinel
    // callback too. A routine `<!here>` in a group DM must not enter the
    // append-only channel-thread ledger.
    const { slack, store, syncThread } = setup();

    await (slack as any).handleChannelMessage({
      channel: "D1",
      channel_type: "im",
      ts: "104.0",
      text: "hey <@U111>",
    });

    expect(syncThread).not.toHaveBeenCalled();
    expect(store.map.has("sync_thread:D1:104.0")).toBe(false);
  });

  it("ignores a group-DM (mpim) event even when it mentions the user", async () => {
    const { slack, store, syncThread } = setup();

    await (slack as any).handleChannelMessage({
      channel: "G1",
      channel_type: "mpim",
      ts: "105.0",
      text: "<!here> check this out",
    });

    expect(syncThread).not.toHaveBeenCalled();
    expect(store.map.has("sync_thread:G1:105.0")).toBe(false);
  });

  it("falls back to the DM roster when the event carries no channel_type", async () => {
    // `channel_type` is the authoritative classification, but the cost of
    // getting this wrong is unrecoverable: the subscription ledger is
    // append-only, so a group DM written into it duplicates the conversation
    // as a second Plot thread forever. An event missing the field must fail
    // CLOSED against the known DM roster rather than default to "channel".
    const { slack, store, syncThread } = setup({ dm_channels: ["G1"] });

    await (slack as any).handleChannelMessage({
      channel: "G1",
      // no channel_type
      ts: "107.0",
      text: "<!here> check this out",
    });

    expect(syncThread).not.toHaveBeenCalled();
    expect(store.map.has("sync_thread:G1:107.0")).toBe(false);
  });

  it("still routes a channel_type-less event for a channel that is not a DM", async () => {
    // The fallback must not swallow ordinary channel mentions that happen to
    // arrive without the field.
    const { slack, store, syncThread } = setup({ dm_channels: ["G1"] });

    await (slack as any).handleChannelMessage({
      channel: "C1",
      ts: "108.0",
      text: "hey <@U111>",
    });

    expect(syncThread).toHaveBeenCalledWith("C1", "108.0");
    expect(store.map.get("sync_thread:C1:108.0")).toBe(true);
  });

  it("warns and drops the mention when no Slack identity is cached", async () => {
    const store = makeStore(); // no slack_user_id seeded
    const slack = makeSlack({
      store,
      integrationsGet: vi.fn(),
      createWebhook: vi.fn(),
    });
    const syncThread = vi.fn().mockResolvedValue(undefined);
    (slack as any).syncSubscribedThread = syncThread;
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});

    await (slack as any).handleChannelMessage({
      channel: "C1",
      ts: "106.0",
      text: "hey <@U111>",
    });

    expect(syncThread).not.toHaveBeenCalled();
    expect(store.map.has("sync_thread:C1:106.0")).toBe(false);
    expect(warn).toHaveBeenCalledWith(
      expect.stringContaining("no cached Slack identity")
    );
    warn.mockRestore();
  });
});

describe("webhook registration", () => {
  const auth: Authorization = {
    provider: AuthProvider.Slack,
    actor: { id: "actor-1" },
  } as Authorization;

  function makeRegisterSlack(opts: {
    store: ReturnType<typeof makeStore>;
    integrationsGet: ReturnType<typeof vi.fn>;
  }) {
    const createWebhook = vi.fn().mockResolvedValue("slack://team/tok");
    const scheduleRecurring = vi.fn(async () => {});
    const cancelScheduledTask = vi.fn(async () => {});
    const tools = {
      store: opts.store,
      integrations: { get: opts.integrationsGet },
      network: { createWebhook },
      files: {},
      callbacks: { create: vi.fn(async () => ({ token: "cb" }) as never) },
      tasks: {
        runTask: vi.fn(async () => "task-token"),
        scheduleRecurring,
        cancelScheduledTask,
      },
    };
    const slack = new Slack(
      "twist-instance-1" as never,
      { getTools: () => tools } as never
    );
    return { slack, createWebhook, scheduleRecurring, cancelScheduledTask };
  }

  const grantedToken = (scope: string) => ({
    token: "xoxp-1",
    scopes: [scope],
    provider: { authed_user_id: "U111" },
  });

  const RETRY_KEYS = {
    registerDMWebhook: "dm-webhook-register",
    registerMentionWebhook: "mention-webhook-register",
  } as const;

  /**
   * The scope each registration needs. Using the right one per method matters:
   * a token carrying the other method's scope would make these tests pass on
   * the scope check rather than on the guard actually under test.
   */
  const REQUIRED_SCOPES = {
    registerDMWebhook: "im:history",
    registerMentionWebhook: "channels:history",
  } as const;

  for (const method of [
    "registerDMWebhook",
    "registerMentionWebhook",
  ] as const) {
    describe(method, () => {
      it("does not register while the stored authorization is unreadable", async () => {
        // Registering without it makes the platform throw looking up the
        // integration, which then fails and retries forever on the webhook
        // queue.
        const { slack, createWebhook, scheduleRecurring } = makeRegisterSlack({
          store: makeStore({}), // no stored authorization
          integrationsGet: vi
            .fn()
            .mockResolvedValue(grantedToken(REQUIRED_SCOPES[method])),
        });

        await (slack as any)[method]("C1");

        expect(createWebhook).not.toHaveBeenCalled();
        // ...but the connection would observe nothing at all if this simply
        // gave up: registrations are queued only when channels are mirrored,
        // and a fresh connection is one burst of that.
        expect(scheduleRecurring).toHaveBeenCalledWith(
          RETRY_KEYS[method],
          expect.anything(),
          expect.objectContaining({ intervalMs: expect.any(Number) })
        );
      });

      it("does not register when the token has been removed", async () => {
        // The stored authorization survives token removal, so its presence
        // does not imply a usable token.
        const { slack, createWebhook, scheduleRecurring } = makeRegisterSlack({
          store: makeStore({ auth }),
          integrationsGet: vi.fn().mockResolvedValue(null),
        });

        await (slack as any)[method]("C1");

        expect(createWebhook).not.toHaveBeenCalled();
        expect(scheduleRecurring).toHaveBeenCalledWith(
          RETRY_KEYS[method],
          expect.anything(),
          expect.anything()
        );
      });

      it("stops retrying once the registration takes", async () => {
        const { slack, createWebhook, cancelScheduledTask } =
          makeRegisterSlack({
            store: makeStore({ auth }),
            integrationsGet: vi
              .fn()
              .mockResolvedValue(grantedToken(REQUIRED_SCOPES[method])),
          });

        await (slack as any)[method]("C1");

        expect(createWebhook).toHaveBeenCalledTimes(1);
        expect(cancelScheduledTask).toHaveBeenCalledWith(RETRY_KEYS[method]);
      });
    });
  }

  it("retries when the grant is missing the scope needed to observe channels", async () => {
    // Unlike direct message sync, this scope is required — a grant without it
    // is stale or broken, not a choice. Giving up would leave the connection
    // permanently unable to notice an at-mention even after the user
    // reconnects.
    const { slack, createWebhook, scheduleRecurring } = makeRegisterSlack({
      store: makeStore({ auth }),
      integrationsGet: vi.fn().mockResolvedValue(grantedToken("im:history")),
    });

    await (slack as any).registerMentionWebhook("C1");

    expect(createWebhook).not.toHaveBeenCalled();
    expect(scheduleRecurring).toHaveBeenCalledWith(
      "mention-webhook-register",
      expect.anything(),
      expect.anything()
    );
  });

  it("does not retry when the user simply declined direct message sync", async () => {
    // An optional grant the user turned down is a decision, not a failure.
    const { slack, createWebhook, scheduleRecurring } = makeRegisterSlack({
      store: makeStore({ auth }),
      integrationsGet: vi.fn().mockResolvedValue(grantedToken("channels:history")),
    });

    await (slack as any).registerDMWebhook("C1");

    expect(createWebhook).not.toHaveBeenCalled();
    expect(scheduleRecurring).not.toHaveBeenCalled();
  });

  it("caches the connected user's Slack id from the registration token lookup", async () => {
    const store = makeStore({ auth });
    const { slack } = makeRegisterSlack({
      store,
      integrationsGet: vi.fn().mockResolvedValue(grantedToken("channels:history")),
    });

    await (slack as any).registerMentionWebhook("C1");

    expect(store.map.get("slack_user_id")).toBe("U111");
    expect(store.map.get("mention_webhook_registered")).toBe(true);
  });
});

describe("drainSubscribedThreads", () => {
  function makeDrainSlack(initial: Record<string, unknown> = {}) {
    const store = makeStore(initial);
    const markNeedsReauth = vi.fn(async () => {});
    const tools = {
      store,
      integrations: { get: vi.fn(), markNeedsReauth },
      network: {},
      files: {},
    };
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const slack = new Slack(
      "twist-instance-1" as never,
      { getTools: () => tools } as never
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ) as any;
    vi.spyOn(slack, "getApi").mockResolvedValue({});
    const refresh = vi
      .spyOn(slack, "refreshSlackThread")
      .mockResolvedValue(undefined);
    return { slack, refresh, markNeedsReauth };
  }

  it("refreshes every queued thread", async () => {
    const { slack, refresh } = makeDrainSlack();

    const result = await slack.drainSubscribedThreads(
      ["100.0", "200.0"],
      "C1"
    );

    expect(result).toBeUndefined();
    expect(refresh).toHaveBeenCalledTimes(2);
    expect(refresh).toHaveBeenCalledWith(expect.anything(), "C1", "100.0");
    expect(refresh).toHaveBeenCalledWith(expect.anything(), "C1", "200.0");
  });

  it("keeps every queued thread pending when the Slack token is unavailable", async () => {
    const { slack } = makeDrainSlack();
    vi.spyOn(slack, "getApi").mockRejectedValue(new Error("no token"));

    const result = await slack.drainSubscribedThreads(
      ["100.0", "200.0"],
      "C1"
    );

    expect(result).toEqual({ retry: ["100.0", "200.0"] });
  });

  it("stops the pass on the first rate limit instead of retrying id-by-id", async () => {
    const { slack, refresh } = makeDrainSlack();
    refresh
      .mockResolvedValueOnce(undefined)
      .mockRejectedValueOnce(
        new SlackRateLimitedError("conversations.replies", 60_000)
      );

    const result = await slack.drainSubscribedThreads(
      ["100.0", "200.0", "300.0"],
      "C1"
    );

    expect(result).toEqual({ retry: ["200.0", "300.0"] });
    // 300.0 must never be attempted — it would just be another guaranteed
    // 429 against the same 1rpm-limited method.
    expect(refresh).toHaveBeenCalledTimes(2);
  });

  it("flags the connection for reauth on an auth-shaped permanent error", async () => {
    const { slack, refresh, markNeedsReauth } = makeDrainSlack();
    refresh.mockRejectedValueOnce(
      new SlackPermanentError("conversations.replies", "invalid_auth")
    );

    const result = await slack.drainSubscribedThreads(
      ["100.0", "200.0"],
      "C1"
    );

    expect(markNeedsReauth).toHaveBeenCalledWith("C1");
    expect(result).toEqual({ retry: ["100.0", "200.0"] });
  });

  it("skips a non-auth permanent error and continues the pass", async () => {
    const { slack, refresh, markNeedsReauth } = makeDrainSlack();
    refresh
      .mockRejectedValueOnce(
        new SlackPermanentError("conversations.replies", "thread_not_found")
      )
      .mockResolvedValueOnce(undefined);

    const result = await slack.drainSubscribedThreads(
      ["100.0", "200.0"],
      "C1"
    );

    expect(result).toBeUndefined();
    expect(markNeedsReauth).not.toHaveBeenCalled();
    expect(refresh).toHaveBeenCalledTimes(2);
  });

  it("rethrows an unexpected error instead of swallowing it", async () => {
    const { slack, refresh } = makeDrainSlack();
    refresh.mockRejectedValueOnce(new Error("boom"));

    await expect(
      slack.drainSubscribedThreads(["100.0"], "C1")
    ).rejects.toThrow("boom");
  });
});

describe("onNoteCreated reply targeting", () => {
  function setup(meta: Record<string, unknown>) {
    const postMessage = vi.fn().mockResolvedValue({ ts: "200.0" });
    const slack = makeSlack({
      store: makeStore(),
      integrationsGet: vi.fn().mockResolvedValue({ token: "xoxp-1", provider: {} }),
      createWebhook: vi.fn(),
    });
    (slack as any).getWorkspaceApi = vi.fn().mockResolvedValue({ postMessage });
    return { slack, postMessage, thread: { meta } as any };
  }

  it("nests under the note being replied to", async () => {
    const { slack, postMessage, thread } = setup({
      channelId: "D111",
      threadTs: "100.0",
      reNoteKey: "150.0",
    });

    await slack.onNoteCreated({ content: "sure" } as any, thread);

    expect(postMessage).toHaveBeenCalledWith("D111", "sure", "150.0");
  });

  it("posts top-level in a direct conversation with no reply target", async () => {
    const { slack, postMessage, thread } = setup({
      channelId: "D111",
      threadTs: "100.0",
      direct: true,
    });

    await slack.onNoteCreated({ content: "hello" } as any, thread);

    expect(postMessage).toHaveBeenCalledWith("D111", "hello", undefined);
  });

  it("stays in the Slack thread for a channel thread", async () => {
    const { slack, postMessage, thread } = setup({
      channelId: "C123",
      threadTs: "100.0",
    });

    await slack.onNoteCreated({ content: "ack" } as any, thread);

    expect(postMessage).toHaveBeenCalledWith("C123", "ack", "100.0");
  });
});

describe("buildConversationLink — thread read cursor", () => {
  function buildSlack() {
    const store = makeStore();
    const slack = makeSlack({
      store,
      integrationsGet: vi.fn(),
      createWebhook: vi.fn(),
    });
    vi.spyOn(
      slack as unknown as { isKnownDMChannel: (c: string) => Promise<boolean> },
      "isKnownDMChannel"
    ).mockResolvedValue(false);
    vi.spyOn(
      slack as unknown as {
        customEmojiContext: (c: string) => Promise<{ teamId?: string }>;
      },
      "customEmojiContext"
    ).mockResolvedValue({});
    return { slack, store };
  }

  const parent = {
    type: "message",
    ts: "1700000000.000001",
    thread_ts: "1700000000.000001",
    user: "U1",
    text: "parent",
  };
  const reply = {
    type: "message",
    ts: "1700000002.000000",
    thread_ts: "1700000000.000001",
    user: "U2",
    text: "reply",
  };

  async function build(messages: unknown[]) {
    const { slack } = buildSlack();
    return (slack as unknown as {
      buildConversationLink: (o: unknown) => Promise<{ unread?: boolean } | null>;
    }).buildConversationLink({
      channelId: "C1",
      messages,
      initialSync: false,
    });
  }

  it("marks the link read when the thread's own cursor says read", async () => {
    const link = await build([{ ...parent, unread_count: 0 }, reply]);
    expect(link?.unread).toBe(false);
  });

  it("leaves unread alone when the thread cursor says unread", async () => {
    const link = await build([{ ...parent, unread_count: 2 }, reply]);
    expect(link).not.toHaveProperty("unread");
  });

  it("abstains when the parent carries no thread cursor", async () => {
    const link = await build([parent, reply]);
    expect(link).not.toHaveProperty("unread");
  });

  it("abstains on a root-only link — the channel cursor is the sweep's job", async () => {
    const link = await build([{ ...parent, unread_count: 0 }]);
    expect(link).not.toHaveProperty("unread");
  });

  it("never sets unread true, even when the thread is unread in Slack", async () => {
    const link = await build([{ ...parent, unread_count: 5 }, reply]);
    expect(link?.unread).not.toBe(true);
  });
});

describe("read anchors", () => {
  const parent = {
    type: "message",
    ts: "1700000000.000001",
    thread_ts: "1700000000.000001",
    user: "U1",
    text: "parent",
  };
  const reply = {
    type: "message",
    ts: "1700000002.000000",
    thread_ts: "1700000000.000001",
    user: "U2",
    text: "reply",
  };

  async function build(messages: unknown[]) {
    const store = makeStore();
    const slack = makeSlack({
      store,
      integrationsGet: vi.fn(),
      createWebhook: vi.fn(),
    });
    vi.spyOn(
      slack as unknown as { isKnownDMChannel: (c: string) => Promise<boolean> },
      "isKnownDMChannel"
    ).mockResolvedValue(false);
    vi.spyOn(
      slack as unknown as {
        customEmojiContext: (c: string) => Promise<{ teamId?: string }>;
      },
      "customEmojiContext"
    ).mockResolvedValue({});
    const link = await (slack as unknown as {
      buildConversationLink: (o: unknown) => Promise<{ unread?: boolean } | null>;
    }).buildConversationLink({ channelId: "C1", messages, initialSync: false });
    return { store, link };
  }

  const KEY = "read_anchor:C1:1700000000.000001";

  it("writes an anchor for a link it could not mark read", async () => {
    const { store } = await build([parent]);
    const anchor = store.map.get(KEY) as { newest: string; threaded: boolean };
    expect(anchor.newest).toBe("1700000000.000001");
    expect(anchor.threaded).toBe(false);
  });

  it("marks a threaded link's anchor threaded so the sweep skips it", async () => {
    const { store } = await build([parent, reply]);
    expect((store.map.get(KEY) as { threaded: boolean }).threaded).toBe(true);
  });

  it("deletes the anchor once the link is marked read", async () => {
    const { store, link } = await build([{ ...parent, unread_count: 0 }, reply]);
    expect(link?.unread).toBe(false);
    expect(store.map.has(KEY)).toBe(false);
  });

  it("keys the anchor on the thread root, so a new reply replaces it", async () => {
    const { store } = await build([parent, reply]);
    expect([...store.map.keys()]).toEqual([KEY]);
    expect((store.map.get(KEY) as { newest: string }).newest).toBe(
      "1700000002.000000"
    );
  });

  it("does not write an anchor when there is nothing to save", async () => {
    const { store } = await build([]);
    expect([...store.map.keys()]).toEqual([]);
  });

  it("anchors a direct conversation on the conversation id, never threaded", async () => {
    const store = makeStore();
    const slack = makeSlack({
      store,
      integrationsGet: vi.fn(),
      createWebhook: vi.fn(),
    });
    vi.spyOn(
      slack as unknown as { isKnownDMChannel: (c: string) => Promise<boolean> },
      "isKnownDMChannel"
    ).mockResolvedValue(true);
    vi.spyOn(
      slack as unknown as {
        customEmojiContext: (c: string) => Promise<{ teamId?: string }>;
      },
      "customEmojiContext"
    ).mockResolvedValue({});
    vi.spyOn(
      slack as unknown as {
        dmCounterpartyUserId: (c: string) => Promise<string | null>;
      },
      "dmCounterpartyUserId"
    ).mockResolvedValue("U2");

    await (slack as unknown as {
      buildConversationLink: (o: unknown) => Promise<unknown>;
    }).buildConversationLink({
      channelId: "D1",
      messages: [
        { type: "message", ts: "1700000000.000001", user: "U2", text: "hi" },
        {
          type: "message",
          ts: "1700000002.000000",
          thread_ts: "1700000000.000001",
          user: "U2",
          text: "threaded",
        },
      ],
      initialSync: false,
    });

    const anchor = store.map.get("read_anchor:D1:D1") as {
      newest: string;
      threaded: boolean;
    };
    expect(anchor.newest).toBe("1700000002.000000");
    expect(anchor.threaded).toBe(false);
  });

  it("leaves no anchor for a DM's initial sync — the link is already read", async () => {
    const store = makeStore();
    const slack = makeSlack({
      store,
      integrationsGet: vi.fn(),
      createWebhook: vi.fn(),
    });
    vi.spyOn(
      slack as unknown as { isKnownDMChannel: (c: string) => Promise<boolean> },
      "isKnownDMChannel"
    ).mockResolvedValue(true);
    vi.spyOn(
      slack as unknown as {
        customEmojiContext: (c: string) => Promise<{ teamId?: string }>;
      },
      "customEmojiContext"
    ).mockResolvedValue({});
    vi.spyOn(
      slack as unknown as {
        dmCounterpartyUserId: (c: string) => Promise<string | null>;
      },
      "dmCounterpartyUserId"
    ).mockResolvedValue("U2");

    const link = await (slack as unknown as {
      buildConversationLink: (o: unknown) => Promise<{ unread?: boolean } | null>;
    }).buildConversationLink({
      channelId: "D1",
      messages: [
        { type: "message", ts: "1700000000.000001", user: "U2", text: "hi" },
      ],
      initialSync: true,
    });

    expect(link?.unread).toBe(false);
    expect(store.map.has("read_anchor:D1:D1")).toBe(false);
  });
});
