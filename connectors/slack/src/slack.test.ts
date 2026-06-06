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
