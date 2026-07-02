import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { TRANSIENT_ALARM_RETRY_DELAYS_MS } from "./alarm-retry";
import { EmailNotify, priorityDeepLinkUrl } from "./email-notify";

const { captureExceptionSpy, captureSpy } = vi.hoisted(() => ({
  captureExceptionSpy: vi.fn(),
  captureSpy: vi.fn(),
}));

vi.mock("posthog-node", () => ({
  PostHog: class {
    captureException = captureExceptionSpy;
    capture = captureSpy;
    async shutdown() {}
  },
}));

describe("priorityDeepLinkUrl", () => {
  it("builds a canonical /p/ priority deep link", () => {
    expect(
      priorityDeepLinkUrl(
        "https://app.plot.day",
        "019d91c2-4d0d-798e-b920-4340faf6b2ff"
      )
    ).toBe("https://app.plot.day/p/Ca5nzyiWJLyDo43mNqPW6");
  });

  it("does not emit the deprecated ?tab=activity query param", () => {
    const url = priorityDeepLinkUrl(
      "https://app.plot.day",
      "019d91c2-4d0d-798e-b920-4340faf6b2ff"
    );
    // The old digest link was `/{id}?tab=activity`, a stale bare-segment form
    // whose query param is ignored by the app router. The canonical form has
    // no query string at all.
    expect(url).not.toContain("tab=activity");
    expect(url).not.toContain("?");
  });
});

describe("EmailNotify alarm failure handling", () => {
  const NOW = 1_750_000_000_000;
  const USER_ID = "019d91c2-4d0d-798e-b920-4340faf6b2ff";

  let storageMap: Map<string, unknown>;
  let setAlarm: ReturnType<typeof vi.fn>;
  let getAlarm: ReturnType<typeof vi.fn>;
  let broadcastFetch: ReturnType<typeof vi.fn>;
  let emailNotify: EmailNotify;

  beforeEach(() => {
    vi.spyOn(Date, "now").mockReturnValue(NOW);
    captureExceptionSpy.mockClear();
    captureSpy.mockClear();

    storageMap = new Map<string, unknown>();
    setAlarm = vi.fn();
    getAlarm = vi.fn(async () => null);
    broadcastFetch = vi.fn();

    const ctx = {
      storage: {
        get: vi.fn(async (key: string) => storageMap.get(key)),
        put: vi.fn(async (key: string, value: unknown) => {
          storageMap.set(key, value);
        }),
        delete: vi.fn(async (key: string) => {
          storageMap.delete(key);
        }),
        setAlarm,
        getAlarm,
      },
      waitUntil: vi.fn(),
    };
    const env = {
      POSTHOG_API_KEY: "key",
      POSTHOG_HOST: "host",
      NOTIFICATION_DELAY_MULTIPLIER: "1.0",
      BROADCAST: {
        idFromName: vi.fn(() => "broadcast-id"),
        get: vi.fn(() => ({ fetch: broadcastFetch })),
      },
    };
    emailNotify = new EmailNotify(
      ctx as unknown as DurableObjectState,
      env as never
    );
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  const seedPendingCycle = () => {
    storageMap.set("userId", USER_ID);
    storageMap.set("pendingNotifyTime", NOW - 1000);
  };

  it("keeps the pending digest and reschedules on a transient failure", async () => {
    seedPendingCycle();
    broadcastFetch.mockRejectedValue(
      new Error("Connection terminated unexpectedly")
    );

    await emailNotify.alarm();

    // The digest cycle survives: pendingNotifyTime intact, retry alarm armed.
    expect(storageMap.get("pendingNotifyTime")).toBe(NOW - 1000);
    expect(setAlarm).toHaveBeenCalledWith(
      NOW + TRANSIENT_ALARM_RETRY_DELAYS_MS[0]
    );
    // Transient blips are counted, not paged.
    expect(captureExceptionSpy).not.toHaveBeenCalled();
    expect(captureSpy).toHaveBeenCalledWith(
      expect.objectContaining({ event: "push.transient" })
    );
  });

  it("abandons the cycle and captures on an unexpected failure", async () => {
    seedPendingCycle();
    broadcastFetch.mockRejectedValue(new Error("boom"));

    await emailNotify.alarm();

    expect(storageMap.has("pendingNotifyTime")).toBe(false);
    expect(setAlarm).not.toHaveBeenCalled();
    expect(captureExceptionSpy).toHaveBeenCalled();
  });

  it("captures and abandons once the transient retry budget is exhausted", async () => {
    seedPendingCycle();
    broadcastFetch.mockRejectedValue(
      new Error("Connection terminated unexpectedly")
    );

    for (let i = 0; i < TRANSIENT_ALARM_RETRY_DELAYS_MS.length; i++) {
      await emailNotify.alarm();
    }
    expect(captureExceptionSpy).not.toHaveBeenCalled();
    expect(storageMap.has("pendingNotifyTime")).toBe(true);

    await emailNotify.alarm();

    expect(captureExceptionSpy).toHaveBeenCalledTimes(1);
    expect(storageMap.has("pendingNotifyTime")).toBe(false);
  });

  const notifyRequest = () =>
    new Request("http://do/notify", {
      method: "POST",
      body: JSON.stringify({ userId: USER_ID }),
    });

  it("re-arms a lost alarm for an existing pending cycle on notify", async () => {
    seedPendingCycle();
    getAlarm.mockResolvedValue(null);

    await emailNotify.fetch(notifyRequest());

    // Pending window kept (earlier batching anchor), alarm restored.
    expect(storageMap.get("pendingNotifyTime")).toBe(NOW - 1000);
    expect(setAlarm).toHaveBeenCalledTimes(1);
  });

  it("leaves an already-armed pending cycle alone on notify", async () => {
    seedPendingCycle();
    getAlarm.mockResolvedValue(NOW + 60_000);

    await emailNotify.fetch(notifyRequest());

    expect(setAlarm).not.toHaveBeenCalled();
  });
});
