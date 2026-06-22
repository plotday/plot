import { env, runInDurableObject } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";

import type { CallbacksState } from "../callbacks";

declare module "cloudflare:test" {
  interface ProvidedEnv {
    CALLBACKS: DurableObjectNamespace<CallbacksState>;
    RUN_QUEUE: Queue<unknown>;
  }
}

const TWIST_INSTANCE = "22222222-2222-2222-2222-222222222222";

function getCallbacks(name: string): DurableObjectStub<CallbacksState> {
  return env.CALLBACKS.get(env.CALLBACKS.idFromName(name));
}

function createRecurring(
  stub: DurableObjectStub<CallbacksState>,
  opts: { taskKey: string; intervalMs: number; firstRunAt?: Date }
): Promise<string> {
  return stub.create({
    twistInstanceId: TWIST_INSTANCE,
    path: ["tasks"],
    version: "test",
    functionName: "scheduledSend",
    extraArgs: ["inner-callback-token"],
    callAt: opts.firstRunAt,
    taskKey: opts.taskKey,
    recurringIntervalMs: opts.intervalMs,
  });
}

describe("CallbacksState recurring create()", () => {
  let stub: DurableObjectStub<CallbacksState>;
  beforeEach(() => {
    stub = getCallbacks(`recurring-${crypto.randomUUID()}`);
  });

  it("clamps call_at to no later than now + intervalMs", async () => {
    const interval = 60 * 60 * 1000; // 1h
    // firstRunAt far in the future (10h) must be clamped down to ~now+1h.
    const token = await createRecurring(stub, {
      taskKey: "poll:1",
      intervalMs: interval,
      firstRunAt: new Date(Date.now() + 10 * 60 * 60 * 1000),
    });
    const loaded = await stub.validateAndLoad(token);
    if ("__error" in loaded) throw new Error("row missing");
    const callAt = loaded.callback.callAt!.getTime();
    expect(callAt).toBeLessThanOrEqual(Date.now() + interval + 1000);
    expect(callAt).toBeGreaterThan(Date.now() + interval - 5 * 60 * 1000);
  });

  it("keeps an earlier firstRunAt (ceiling pulls earlier, never later)", async () => {
    const interval = 60 * 60 * 1000;
    const soon = new Date(Date.now() + 5 * 60 * 1000); // 5 min
    const token = await createRecurring(stub, {
      taskKey: "renew:1",
      intervalMs: interval,
      firstRunAt: soon,
    });
    const loaded = await stub.validateAndLoad(token);
    if ("__error" in loaded) throw new Error("row missing");
    expect(loaded.callback.callAt!.getTime()).toBe(soon.getTime());
  });
});

describe("CallbacksState recurring alarm()", () => {
  let stub: DurableObjectStub<CallbacksState>;
  beforeEach(() => {
    stub = getCallbacks(`recurring-alarm-${crypto.randomUUID()}`);
  });

  it("advances a due recurring row instead of deleting it", async () => {
    const interval = 60 * 60 * 1000; // 1h
    // Past firstRunAt → clamped to past → due immediately.
    const token = await createRecurring(stub, {
      taskKey: "poll:1",
      intervalMs: interval,
      firstRunAt: new Date(Date.now() - 1000),
    });

    await runInDurableObject(stub, (instance: CallbacksState) => instance.alarm());

    const loaded = await stub.validateAndLoad(token);
    if ("__error" in loaded) throw new Error("recurring row was deleted");
    const callAt = loaded.callback.callAt!.getTime();
    expect(callAt).toBeGreaterThan(Date.now() + interval - 5000);
    expect(callAt).toBeLessThan(Date.now() + interval + 5000);
  });

  it("advances even when the row was the only one (re-arms alarm)", async () => {
    const interval = 30 * 60 * 1000;
    await createRecurring(stub, {
      taskKey: "renew:1",
      intervalMs: interval,
      firstRunAt: new Date(Date.now() - 1000),
    });
    await runInDurableObject(stub, (instance: CallbacksState) => instance.alarm());
    // A live recurring row remains → reconcile sees the chain as alive.
    expect(await stub.hasLiveRecurringTask(TWIST_INSTANCE)).toBe(true);
  });
});

describe("CallbacksState recurring liveness", () => {
  let stub: DurableObjectStub<CallbacksState>;
  beforeEach(() => {
    stub = getCallbacks(`recurring-live-${crypto.randomUUID()}`);
  });

  it("hasLiveRecurringTask reflects presence of a recurring row", async () => {
    expect(await stub.hasLiveRecurringTask(TWIST_INSTANCE)).toBe(false);
    await createRecurring(stub, { taskKey: "poll:1", intervalMs: 60_000 });
    expect(await stub.hasLiveRecurringTask(TWIST_INSTANCE)).toBe(true);
  });

  it("needsRecurringRecovery is true only after a recurring task is cancelled", async () => {
    expect(await stub.needsRecurringRecovery(TWIST_INSTANCE)).toBe(false); // never registered
    await createRecurring(stub, { taskKey: "poll:1", intervalMs: 60_000 });
    expect(await stub.needsRecurringRecovery(TWIST_INSTANCE)).toBe(false); // live
    await stub.deleteByTaskKey(TWIST_INSTANCE, "poll:1");
    expect(await stub.needsRecurringRecovery(TWIST_INSTANCE)).toBe(true); // marked + no live row
  });
});
