import { isTransientDbError } from "../db";
import { isTransientDoResetError } from "../utils/transient-error";

/**
 * Reschedule cadence after a transient platform error interrupts a DO alarm.
 * Capped so a misclassified persistent error can't loop indefinitely — after
 * the ladder is exhausted the caller captures the error and falls back to its
 * external recovery path (next notify()/spend()/enqueue, or SyncRecovery).
 */
export const TRANSIENT_ALARM_RETRY_DELAYS_MS = [2000, 4000, 8000] as const;

/**
 * Transient infrastructure faults that can interrupt a DO alarm mid-run:
 * the Cloudflare DO-reset family (storage-timeout reset, generic platform
 * fault, DO-to-DO fetch drop) plus the Hyperdrive/pg connection drops that
 * surface on the same path. Both self-resolve within seconds, so alarms
 * should reschedule via {@link TransientAlarmRetry} instead of paging
 * PostHog Error Tracking on the first occurrence.
 */
export function isTransientAlarmError(error: unknown): boolean {
  return isTransientDoResetError(error) || isTransientDbError(error);
}

export type TransientRescheduleOptions = {
  /** The DO's storage, used to arm the retry alarm. */
  storage: { setAlarm(scheduledTime: number): void | Promise<void> };
  logger: { warn(message: string, context?: Record<string, unknown>): void };
  error: unknown;
  /** DO class name for log lines, e.g. "TwistSync". */
  durableObject: string;
  /** Extra structured-log context (user_id, twist_instance_id, ...). */
  logContext?: Record<string, unknown>;
  /** Runs before setAlarm — e.g. mark an in-memory pendingAlarm flag. */
  beforeSchedule?: () => void;
  /** Runs when setAlarm itself throws — e.g. clear the pendingAlarm flag. */
  onScheduleFailed?: () => void;
};

/**
 * Per-DO retry budget for alarms interrupted by transient platform errors
 * (extracted from UserSync so every alarm-bearing DO shares one convention).
 *
 * Usage, inside the alarm's catch block:
 *
 *   if (isTransientAlarmError(error)) {
 *     if (await this.retry.reschedule({ storage: this.ctx.storage, ... })) {
 *       return; // retry alarm armed (or storage too broken to arm one)
 *     }
 *   }
 *   // budget exhausted or a real error: captureException as usual
 *
 * The counter is in-memory: a DO restart wipes it, restoring the full budget.
 * That is fail-safe — worst case a persistent-but-misclassified error gets a
 * fresh ladder after each reset, and each exhaustion still captures. Call
 * `reset()` whenever fresh work arrives (notify/enqueue/spend) so real
 * activity restores the full budget, mirroring UserSync.
 */
export class TransientAlarmRetry {
  private attempts = 0;

  constructor(
    private readonly delaysMs: readonly number[] = TRANSIENT_ALARM_RETRY_DELAYS_MS
  ) {}

  /** Restore the full retry budget. */
  reset(): void {
    this.attempts = 0;
  }

  /**
   * Walk the delay ladder and arm a retry alarm.
   *
   * Returns `true` when the error is handled — a retry alarm was scheduled,
   * or setAlarm itself failed (storage is in the same transient state; the
   * caller's external recovery path takes over). Returns `false` when the
   * budget is exhausted: the error is no longer "transient" by any useful
   * definition and the caller should captureException. The budget resets on
   * exhaustion so a later, unrelated blip gets a fresh ladder.
   */
  async reschedule(opts: TransientRescheduleOptions): Promise<boolean> {
    const delayMs = this.delaysMs[this.attempts];
    if (delayMs === undefined) {
      this.attempts = 0;
      return false;
    }
    this.attempts += 1;

    opts.logger.warn(
      `${opts.durableObject} alarm interrupted by transient platform error, rescheduling`,
      {
        transient_attempt: this.attempts,
        retry_delay_ms: delayMs,
        error_message:
          opts.error instanceof Error ? opts.error.message : String(opts.error),
        ...opts.logContext,
      }
    );

    try {
      opts.beforeSchedule?.();
      await opts.storage.setAlarm(Date.now() + delayMs);
    } catch (rescheduleError) {
      // setAlarm can fail when DO storage is in the same transient state.
      // Fall back to the caller's external recovery — we can't do better
      // without storage, and capturing here would page for platform noise.
      opts.onScheduleFailed?.();
      opts.logger.warn(
        `Failed to reschedule ${opts.durableObject} alarm after transient error`,
        {
          reschedule_error:
            rescheduleError instanceof Error
              ? rescheduleError.message
              : String(rescheduleError),
          ...opts.logContext,
        }
      );
    }
    return true;
  }
}
