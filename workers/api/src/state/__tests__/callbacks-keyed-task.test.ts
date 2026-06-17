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
const future = () => new Date(Date.now() + 60 * 60 * 1000);

/** Schedule a keyed task; returns its cancellation token. */
function schedule(
  stub: DurableObjectStub<CallbacksState>,
  taskKey: string
): Promise<string> {
  return stub.create({
    twistInstanceId: TWIST_INSTANCE,
    path: ["tasks"],
    // Pass version explicitly so create() doesn't hit the DB to resolve it.
    version: "test",
    functionName: "scheduledSend",
    extraArgs: ["inner-callback-token"],
    callAt: future(),
    taskKey,
  });
}

/** True if the callback row for this token still exists. */
async function exists(
  stub: DurableObjectStub<CallbacksState>,
  token: string
): Promise<boolean> {
  const loaded = await stub.validateAndLoad(token);
  return !("__error" in loaded && loaded.__error);
}

describe("CallbacksState keyed scheduled tasks", () => {
  let stub: DurableObjectStub<CallbacksState>;

  beforeEach(() => {
    stub = getCallbacks(`keyed-${crypto.randomUUID()}`);
  });

  it("replaces the prior task when scheduling the same key again", async () => {
    const first = await schedule(stub, "watch-renewal:folder1");
    const second = await schedule(stub, "watch-renewal:folder1");

    // The first task is gone (atomically replaced); only the second is live.
    expect(await exists(stub, first)).toBe(false);
    expect(await exists(stub, second)).toBe(true);
  });

  it("keeps distinct keys independent", async () => {
    const a = await schedule(stub, "watch-renewal:folderA");
    const b = await schedule(stub, "watch-renewal:folderB");

    expect(await exists(stub, a)).toBe(true);
    expect(await exists(stub, b)).toBe(true);
  });

  it("cancelScheduledTask removes the task for its key only", async () => {
    const a = await schedule(stub, "watch-renewal:folderA");
    const b = await schedule(stub, "watch-renewal:folderB");

    await stub.deleteByTaskKey(TWIST_INSTANCE, "watch-renewal:folderA");

    expect(await exists(stub, a)).toBe(false);
    expect(await exists(stub, b)).toBe(true);
  });

  it("cancelScheduledTask is a no-op for an unknown key", async () => {
    const a = await schedule(stub, "watch-renewal:folderA");

    await stub.deleteByTaskKey(TWIST_INSTANCE, "no-such-key");

    expect(await exists(stub, a)).toBe(true);
  });

  it("does not replace non-keyed tasks", async () => {
    const t1 = await stub.create({
      twistInstanceId: TWIST_INSTANCE,
      path: ["tasks"],
      version: "test",
      functionName: "scheduledSend",
      extraArgs: ["inner-1"],
      callAt: future(),
    });
    const t2 = await stub.create({
      twistInstanceId: TWIST_INSTANCE,
      path: ["tasks"],
      version: "test",
      functionName: "scheduledSend",
      extraArgs: ["inner-2"],
      callAt: future(),
    });

    // Without a taskKey there is no singleton semantics — both survive.
    expect(await exists(stub, t1)).toBe(true);
    expect(await exists(stub, t2)).toBe(true);
  });
});
