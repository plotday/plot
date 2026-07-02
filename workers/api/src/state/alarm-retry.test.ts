import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import {
  TRANSIENT_ALARM_RETRY_DELAYS_MS,
  TransientAlarmRetry,
  isTransientAlarmError,
} from "./alarm-retry";

describe("isTransientAlarmError", () => {
  it("classifies DO reset / platform faults as transient", () => {
    expect(
      isTransientAlarmError(
        new Error(
          "Durable Object storage operation exceeded timeout which caused object to be reset"
        )
      )
    ).toBe(true);
    expect(
      isTransientAlarmError(new Error("internal error; reference = ab12cd"))
    ).toBe(true);
    expect(isTransientAlarmError(new Error("Network connection lost"))).toBe(
      true
    );
  });

  it("classifies Hyperdrive/pg connection drops as transient", () => {
    expect(
      isTransientAlarmError(new Error("Connection terminated unexpectedly"))
    ).toBe(true);
    expect(
      isTransientAlarmError(
        new Error("Timed out while waiting for an open slot in the pool.")
      )
    ).toBe(true);
  });

  it("does not classify ordinary errors or non-Errors as transient", () => {
    expect(isTransientAlarmError(new Error("boom"))).toBe(false);
    expect(isTransientAlarmError("Network connection lost")).toBe(false);
    expect(isTransientAlarmError(undefined)).toBe(false);
  });
});

describe("TransientAlarmRetry", () => {
  const NOW = 1_750_000_000_000;
  let setAlarm: ReturnType<typeof vi.fn>;
  let logger: { warn: ReturnType<typeof vi.fn> };

  beforeEach(() => {
    vi.spyOn(Date, "now").mockReturnValue(NOW);
    setAlarm = vi.fn();
    logger = { warn: vi.fn() };
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  const reschedule = (retry: TransientAlarmRetry, extra?: object) =>
    retry.reschedule({
      storage: { setAlarm },
      logger,
      error: new Error("Network connection lost"),
      durableObject: "TestDO",
      ...extra,
    });

  it("walks the capped delay ladder, then reports exhaustion", async () => {
    const retry = new TransientAlarmRetry();

    for (const [i, delayMs] of TRANSIENT_ALARM_RETRY_DELAYS_MS.entries()) {
      await expect(reschedule(retry)).resolves.toBe(true);
      expect(setAlarm).toHaveBeenNthCalledWith(i + 1, NOW + delayMs);
    }

    // Budget exhausted: no further alarm, caller should capture.
    await expect(reschedule(retry)).resolves.toBe(false);
    expect(setAlarm).toHaveBeenCalledTimes(TRANSIENT_ALARM_RETRY_DELAYS_MS.length);
  });

  it("restores the full budget after exhaustion", async () => {
    const retry = new TransientAlarmRetry();
    for (let i = 0; i < TRANSIENT_ALARM_RETRY_DELAYS_MS.length; i++) {
      await reschedule(retry);
    }
    await expect(reschedule(retry)).resolves.toBe(false);

    // A later transient failure starts a fresh ladder.
    await expect(reschedule(retry)).resolves.toBe(true);
    expect(setAlarm).toHaveBeenLastCalledWith(
      NOW + TRANSIENT_ALARM_RETRY_DELAYS_MS[0]
    );
  });

  it("reset() restores the budget mid-ladder", async () => {
    const retry = new TransientAlarmRetry();
    await reschedule(retry);
    await reschedule(retry);

    retry.reset();

    await expect(reschedule(retry)).resolves.toBe(true);
    expect(setAlarm).toHaveBeenLastCalledWith(
      NOW + TRANSIENT_ALARM_RETRY_DELAYS_MS[0]
    );
  });

  it("runs beforeSchedule before setAlarm", async () => {
    const retry = new TransientAlarmRetry();
    const order: string[] = [];
    setAlarm.mockImplementation(() => {
      order.push("setAlarm");
    });

    await reschedule(retry, {
      beforeSchedule: () => {
        order.push("beforeSchedule");
      },
    });

    expect(order).toEqual(["beforeSchedule", "setAlarm"]);
  });

  it("treats a setAlarm failure as handled and runs onScheduleFailed", async () => {
    const retry = new TransientAlarmRetry();
    setAlarm.mockRejectedValue(new Error("storage is broken too"));
    const onScheduleFailed = vi.fn();

    // Handled (true): the caller falls back to its external recovery path
    // (next notify / SyncRecovery) instead of capturing a transient blip.
    await expect(reschedule(retry, { onScheduleFailed })).resolves.toBe(true);
    expect(onScheduleFailed).toHaveBeenCalledTimes(1);
    expect(logger.warn).toHaveBeenCalled();
  });

  it("supports a custom delay ladder", async () => {
    const retry = new TransientAlarmRetry([100]);
    await expect(reschedule(retry)).resolves.toBe(true);
    expect(setAlarm).toHaveBeenLastCalledWith(NOW + 100);
    await expect(reschedule(retry)).resolves.toBe(false);
  });
});
