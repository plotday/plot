import { describe, it, expect } from "vitest";
import { enableActivatedChannels } from "./management";

function spyWrapper() {
  const calls: Array<{ method: string; args: any[] }> = [];
  return {
    calls,
    wrapper: {
      callCallback: async (_path: string[], method: string, ...args: any[]) => {
        calls.push({ method, args });
        return undefined;
      },
    },
  };
}

describe("enableActivatedChannels", () => {
  it("issues one enableSyncBatch per provider regardless of channel count", async () => {
    const { wrapper, calls } = spyWrapper();
    const syncables = [
      { provider: "google", syncableId: "mail:INBOX" },
      { provider: "google", syncableId: "calendar:primary" },
      { provider: "google", syncableId: "tasks:list1" },
      { provider: "google", syncableId: "contacts:all" },
    ];
    const descriptors = await enableActivatedChannels(wrapper as any, { google: "tools:integrations" }, syncables, "actor-1", console);

    const batch = calls.filter((c) => c.method === "enableSyncBatch");
    expect(batch).toHaveLength(1);
    expect(batch[0].args[0]).toBe("google");
    expect(batch[0].args[1]).toEqual(["mail:INBOX", "calendar:primary", "tasks:list1", "contacts:all"]);
    // enableSyncBatch is called with dispatch:false (5th positional arg = options)
    expect(batch[0].args[4]).toEqual({ dispatch: false });
    expect(calls.filter((c) => c.method === "initAutoEnableDefault")).toHaveLength(1);
    expect(calls.filter((c) => c.method === "initAutoThreadingDefault")).toHaveLength(1);
    // No per-channel enableSync calls remain.
    expect(calls.some((c) => c.method === "enableSync")).toBe(false);
    // Returns one descriptor per successfully enabled provider
    expect(descriptors).toEqual([
      { provider: "google", actorId: "actor-1", channelIds: ["mail:INBOX", "calendar:primary", "tasks:list1", "contacts:all"], integrationsPath: "tools:integrations" },
    ]);
  });

  it("uses the connection-bound actor per provider, overriding the fallback", async () => {
    // Regression: a multi-contact user's channel must be enabled under the SAME
    // actor the auth token was stored under (twist_instance_connection.actor_id),
    // not a freshly-guessed owner contact. Otherwise channel_config.enabledBy
    // diverges from `auth_token:{provider}:{actor}` and every sync throws
    // "has no stored credentials — reconnect".
    const { wrapper, calls } = spyWrapper();
    const syncables = [{ provider: "linkedin", syncableId: "acc_123" }];
    const descriptors = await enableActivatedChannels(
      wrapper as any,
      { linkedin: "tools:integrations" },
      syncables,
      "fallback-contact",
      console,
      undefined,
      { linkedin: "bound-actor" }
    );

    const batch = calls.filter((c) => c.method === "enableSyncBatch");
    expect(batch).toHaveLength(1);
    // 3rd positional arg (index 2) is the actorId passed to enableSyncBatch.
    expect(batch[0].args[2]).toBe("bound-actor");
    // Auto-enable/threading defaults must use the same bound actor.
    expect(calls.find((c) => c.method === "initAutoEnableDefault")?.args[1]).toBe("bound-actor");
    expect(calls.find((c) => c.method === "initAutoThreadingDefault")?.args[1]).toBe("bound-actor");
    expect(descriptors[0].actorId).toBe("bound-actor");
  });

  it("falls back to the passed actor when no connection actor is mapped", async () => {
    const { wrapper, calls } = spyWrapper();
    await enableActivatedChannels(
      wrapper as any,
      { google: "tools:integrations" },
      [{ provider: "google", syncableId: "mail:INBOX" }],
      "actor-1",
      console,
      undefined,
      { linkedin: "bound-actor" } // no entry for google
    );
    const batch = calls.filter((c) => c.method === "enableSyncBatch");
    expect(batch[0].args[2]).toBe("actor-1");
  });

  it("skips providers with no integrations path", async () => {
    const { wrapper, calls } = spyWrapper();
    await enableActivatedChannels(wrapper as any, {}, [{ provider: "google", syncableId: "mail:INBOX" }], "actor-1", { warn: () => {} });
    expect(calls).toHaveLength(0);
  });

  it("calls captureException and continues on enableSyncBatch failure", async () => {
    const calls: Array<{ method: string; args: any[] }> = [];
    const wrapper = {
      callCallback: async (_path: string[], method: string, ...args: any[]) => {
        calls.push({ method, args });
        if (method === "enableSyncBatch") {
          throw new Error("RPC failure");
        }
        return undefined;
      },
    };
    const capturedErrors: Array<{ error: unknown; context: { provider: string; operation: string } }> = [];
    const captureException = (error: unknown, context: { provider: string; operation: string }) => {
      capturedErrors.push({ error, context });
    };

    // Should not throw, returns empty descriptors (provider failed so nothing pushed)
    await expect(
      enableActivatedChannels(
        wrapper as any,
        { google: "tools:integrations" },
        [{ provider: "google", syncableId: "mail:INBOX" }],
        "actor-1",
        { warn: () => {} },
        captureException
      )
    ).resolves.toEqual([]);

    // captureException called once with correct context
    expect(capturedErrors).toHaveLength(1);
    expect(capturedErrors[0].context).toEqual({ provider: "google", operation: "enableSyncBatch" });

    // Subsequent methods for the same provider still ran (warn-and-continue isolation)
    expect(calls.filter((c) => c.method === "initAutoEnableDefault")).toHaveLength(1);
    expect(calls.filter((c) => c.method === "initAutoThreadingDefault")).toHaveLength(1);
  });
});
