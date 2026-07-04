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

const TWIST_INSTANCE = "11111111-1111-1111-1111-111111111111";
const inMs = (ms: number) => new Date(Date.now() + ms);

/** Create a plain (non-scheduled) callback row — the "inner" task callback. */
function createInner(
  stub: DurableObjectStub<CallbacksState>
): Promise<string> {
  return stub.create({
    twistInstanceId: TWIST_INSTANCE,
    path: ["tasks"],
    version: "test",
    functionName: "incrementalSyncBatch",
  });
}

/** Schedule a keyed wrapper task around an inner callback token. */
function schedule(
  stub: DurableObjectStub<CallbacksState>,
  taskKey: string,
  innerToken: string,
  runAt: Date,
  coalesce?: boolean
): Promise<string> {
  return stub.create({
    twistInstanceId: TWIST_INSTANCE,
    path: ["tasks"],
    version: "test",
    functionName: "scheduledSend",
    extraArgs: [innerToken],
    callAt: runAt,
    taskKey,
    ...(coalesce !== undefined ? { coalesce } : {}),
  });
}

async function loadCallAt(
  stub: DurableObjectStub<CallbacksState>,
  token: string
): Promise<Date | undefined> {
  const loaded = await stub.validateAndLoad(token);
  if ("__error" in loaded && loaded.__error) {
    throw new Error(`callback ${token} not found: ${String(loaded.type)}`);
  }
  return (loaded as { callback: { callAt?: Date } }).callback.callAt;
}

async function exists(
  stub: DurableObjectStub<CallbacksState>,
  token: string
): Promise<boolean> {
  const loaded = await stub.validateAndLoad(token);
  return !("__error" in loaded && loaded.__error);
}

describe("CallbacksState coalesced keyed tasks", () => {
  let stub: DurableObjectStub<CallbacksState>;

  beforeEach(() => {
    stub = getCallbacks(`coalesce-${crypto.randomUUID()}`);
  });

  it("creates normally when no pending task exists for the key", async () => {
    const inner = await createInner(stub);
    const token = await schedule(stub, "sync", inner, inMs(10_000), true);

    expect(await exists(stub, token)).toBe(true);
    expect(await exists(stub, inner)).toBe(true);
  });

  it("keeps the existing pending task and returns its token", async () => {
    const inner1 = await createInner(stub);
    const first = await schedule(stub, "sync", inner1, inMs(10_000), true);

    const inner2 = await createInner(stub);
    const second = await schedule(stub, "sync", inner2, inMs(20_000), true);

    // Coalesced: same live task, same token; earlier fire time retained.
    expect(second).toBe(first);
    expect(await exists(stub, first)).toBe(true);
    // The kept wrapper still uses its original inner callback.
    expect(await exists(stub, inner1)).toBe(true);
  });

  it("deletes the redundant incoming inner callback when coalescing", async () => {
    const inner1 = await createInner(stub);
    await schedule(stub, "sync", inner1, inMs(10_000), true);

    const inner2 = await createInner(stub);
    await schedule(stub, "sync", inner2, inMs(20_000), true);

    // inner2's wrapper was never inserted; its inner callback must not
    // accumulate in the table (webhook-frequency coalescing would otherwise
    // grow it unboundedly).
    expect(await exists(stub, inner2)).toBe(false);
  });

  it("pulls the pending fire time earlier but never pushes it later", async () => {
    const inner1 = await createInner(stub);
    const token = await schedule(stub, "sync", inner1, inMs(60_000), true);

    // A later requested time must NOT push back the pending occurrence.
    const inner2 = await createInner(stub);
    await schedule(stub, "sync", inner2, inMs(120_000), true);
    const afterLater = await loadCallAt(stub, token);
    expect(afterLater!.getTime()).toBeLessThanOrEqual(Date.now() + 61_000);

    // An earlier requested time pulls the fire time forward.
    const inner3 = await createInner(stub);
    await schedule(stub, "sync", inner3, inMs(5_000), true);
    const afterEarlier = await loadCallAt(stub, token);
    expect(afterEarlier!.getTime()).toBeLessThanOrEqual(Date.now() + 6_000);
  });

  it("does not coalesce across distinct keys", async () => {
    const inner1 = await createInner(stub);
    const a = await schedule(stub, "sync:a", inner1, inMs(10_000), true);

    const inner2 = await createInner(stub);
    const b = await schedule(stub, "sync:b", inner2, inMs(10_000), true);

    expect(a).not.toBe(b);
    expect(await exists(stub, a)).toBe(true);
    expect(await exists(stub, b)).toBe(true);
  });

  it("without coalesce, keyed scheduling still replaces (existing semantics)", async () => {
    const inner1 = await createInner(stub);
    const first = await schedule(stub, "sync", inner1, inMs(10_000));

    const inner2 = await createInner(stub);
    const second = await schedule(stub, "sync", inner2, inMs(20_000));

    expect(await exists(stub, first)).toBe(false);
    expect(await exists(stub, second)).toBe(true);
  });
});
