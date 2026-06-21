import { describe, expect, test, vi } from "vitest";
import { UnipileMessagingTool } from "./messaging";

class TestTool extends UnipileMessagingTool {
  protected readonly provider = "testprov";
  // expose protected for the test
  public assert(channelId: string) { return this.assertAccount(channelId); }
}

function make(storeGet: (k: string) => unknown) {
  const t = Object.create(TestTool.prototype) as TestTool & { store: any; client: any; provider: string };
  // Class fields are own properties set by the constructor; set them manually here.
  t.provider = "testprov";
  t.store = { get: vi.fn(async (k: string) => storeGet(k)) };
  return t;
}

describe("assertAccount provider keying", () => {
  test("reads channel_config and auth_token under this.provider", async () => {
    const seen: string[] = [];
    const t = make((k) => { seen.push(k); if (k.startsWith("channel_config:")) return { enabledBy: "actor1" }; if (k.startsWith("auth_token:")) return { access_token: "tok" }; return null; });
    await (t as any).assert("acc1");
    expect(seen).toContain("channel_config:testprov:acc1");
    expect(seen).toContain("auth_token:testprov:actor1");
  });
  test("throws when not enabled", async () => {
    const t = make(() => null);
    await expect((t as any).assert("acc1")).rejects.toThrow(/not enabled/);
  });

  test("flags the connection for re-auth, then throws, when the stored credential is gone", async () => {
    // channel is enabled by actor1, but there is no auth_token with an
    // access_token — the stored Unipile credential was lost/cleared.
    const t = make((k) =>
      k.startsWith("channel_config:") ? { enabledBy: "actor1" } : null,
    );
    const flag = vi.fn(async () => {});
    (t as any).flagChannelNeedsReauth = flag;

    await expect((t as any).assert("acc1")).rejects.toThrow(
      /no stored credentials/,
    );
    // The connection must be flagged for re-auth so the app shows "Reconnect"
    // instead of an eternal "Syncing" — keyed on the responsible actor.
    expect(flag).toHaveBeenCalledWith("acc1", "actor1");
  });
});
