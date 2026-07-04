import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";

import type { CallbacksState } from "../callbacks";

declare module "cloudflare:test" {
  interface ProvidedEnv {
    CALLBACKS: DurableObjectNamespace<CallbacksState>;
  }
}

function getCallbacks(name: string): DurableObjectStub<CallbacksState> {
  return env.CALLBACKS.get(env.CALLBACKS.idFromName(name));
}

const TWIST_INSTANCE = "22222222-2222-2222-2222-222222222222";

/**
 * `nextScheduledCallbackAt` is the stuck-sync watchdog's liveness signal: the
 * soonest future callback that represents the initial sync actively re-arming
 * its next batch. It MUST ignore keyed one-shot tasks (`scheduleTask`, e.g.
 * `gmail-writeback-retry`) and recurring tasks (`scheduleRecurring`, e.g. watch
 * renewals) — those are independent maintenance/background callbacks that share
 * the connection's DO but say nothing about whether the initial backfill is
 * still progressing. Counting them lets a 60-second `gmail-writeback-retry`
 * masquerade as a live sync forever, so the watchdog never escalates an
 * orphaned Google initial sync and the app spins "Syncing" indefinitely.
 */
describe("CallbacksState.nextScheduledCallbackAt (watchdog liveness)", () => {
  let stub: DurableObjectStub<CallbacksState>;

  beforeEach(() => {
    stub = getCallbacks(`liveness-${crypto.randomUUID()}`);
  });

  it("counts an unkeyed one-shot scheduled batch continuation", async () => {
    const callAt = new Date(Date.now() + 5 * 60 * 1000);
    await stub.create({
      twistInstanceId: TWIST_INSTANCE,
      path: ["tasks"],
      version: "test",
      functionName: "initialSyncBatch",
      extraArgs: ["channel", 2],
      callAt,
    });

    expect(await stub.nextScheduledCallbackAt(TWIST_INSTANCE)).toBe(
      callAt.getTime()
    );
  });

  it("ignores a keyed one-shot maintenance task (gmail-writeback-retry)", async () => {
    // Only a keyed writeback-retry is pending, due in 60s. That is NOT the
    // initial sync — the connection is orphaned and must look orphaned.
    await stub.create({
      twistInstanceId: TWIST_INSTANCE,
      path: ["tasks"],
      version: "test",
      functionName: "writeBackRetryBatch",
      callAt: new Date(Date.now() + 60 * 1000),
      taskKey: "gmail-writeback-retry",
    });

    expect(await stub.nextScheduledCallbackAt(TWIST_INSTANCE)).toBeNull();
  });

  it("ignores a recurring maintenance task (watch renewal)", async () => {
    await stub.create({
      twistInstanceId: TWIST_INSTANCE,
      path: ["tasks"],
      version: "test",
      functionName: "renewWatch",
      callAt: new Date(Date.now() + 10 * 60 * 1000),
      taskKey: "watch-renewal:cal1",
      recurringIntervalMs: 3.5 * 24 * 60 * 60 * 1000,
    });

    expect(await stub.nextScheduledCallbackAt(TWIST_INSTANCE)).toBeNull();
  });

  it("returns the batch continuation even when nearer maintenance tasks exist", async () => {
    const batchAt = new Date(Date.now() + 5 * 60 * 1000);
    // A nearer keyed writeback-retry (60s) must not shadow the real signal.
    await stub.create({
      twistInstanceId: TWIST_INSTANCE,
      path: ["tasks"],
      version: "test",
      functionName: "writeBackRetryBatch",
      callAt: new Date(Date.now() + 60 * 1000),
      taskKey: "gmail-writeback-retry",
    });
    await stub.create({
      twistInstanceId: TWIST_INSTANCE,
      path: ["tasks"],
      version: "test",
      functionName: "initialSyncBatch",
      extraArgs: ["channel", 3],
      callAt: batchAt,
    });

    expect(await stub.nextScheduledCallbackAt(TWIST_INSTANCE)).toBe(
      batchAt.getTime()
    );
  });

  it("ignores immediate (call_at NULL) callbacks", async () => {
    await stub.create({
      twistInstanceId: TWIST_INSTANCE,
      path: ["tasks"],
      version: "test",
      functionName: "initialSyncBatch",
      extraArgs: ["channel", 1],
      // no callAt -> immediate, call_at NULL
    });

    expect(await stub.nextScheduledCallbackAt(TWIST_INSTANCE)).toBeNull();
  });
});
