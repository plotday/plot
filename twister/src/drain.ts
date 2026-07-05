import type { Callback } from "./tools/callbacks";
import type { Serializable } from "./index";

/**
 * Coalesced, bounded backlog drain — the platform-owned implementation behind
 * `this.scheduleDrain()` on Twist and Tool.
 *
 * This is THE pattern for webhook-driven sync (and any other high-frequency
 * "something changed, process it soon" trigger):
 *
 * - **Coalescing**: every `scheduleDrain` call (one per provider notification)
 *   collapses into a single pending drain task per `key` — a notification
 *   burst produces one pass, not one queued task per notification.
 * - **Durable dirty set**: notified item ids are persisted under one storage
 *   key per id (a single bulk write per call). A key is deleted only after
 *   the handler has processed that id, so concurrent notification deliveries
 *   and an in-flight drain can never lose ids to a read-modify-write race —
 *   processing is at-least-once.
 * - **Bounded passes**: the handler receives at most `batchSize` ids per
 *   invocation; while a backlog remains, the platform schedules a
 *   continuation. Memory per pass stays flat no matter how large the burst.
 * - **Poison protection**: a per-id attempt counter is bumped when a pass
 *   fails; ids that exhaust `maxAttempts` are dropped (with a log) so one
 *   unprocessable item can't wedge the drain forever.
 *
 * The module is deliberately dependency-light: it operates on a narrow host
 * interface implemented by the Twist/Tool base classes, so the whole
 * mechanism ships (and versions) with the SDK rather than being re-invented
 * per connector.
 */

/**
 * Storage-key namespace for pending drain ids: `__drain__:<key>:<id>` →
 * failed-attempt count. Reserved: the runtime hides this namespace from
 * `store.list()` unless the requested prefix explicitly starts with it.
 */
export const DRAIN_STORE_PREFIX = "__drain__:";

/** Task-key namespace for the coalesced drain task of a given drain key. */
export const DRAIN_TASK_PREFIX = "__drain__:";

/** Default max ids handed to the handler per drain pass. */
export const DEFAULT_DRAIN_BATCH_SIZE = 20;

/** Default coalescing delay before a scheduled drain pass runs. */
export const DEFAULT_DRAIN_DELAY_MS = 10_000;

/** Default per-id failure cap before a pending id is dropped. */
export const DEFAULT_DRAIN_MAX_ATTEMPTS = 5;

/**
 * Result a drain handler may return: ids from the current slice that failed
 * and should be RETRIED on a later pass (their attempt counters are bumped;
 * ids past `maxAttempts` are dropped). Ids not listed are considered
 * processed and released. Returning nothing releases the whole slice.
 */
export type DrainResult = { retry?: string[] } | void;

export type DrainHandler = (
  ids: string[],
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  ...handlerArgs: any[]
) => Promise<DrainResult> | DrainResult;

export type DrainOptions = {
  /**
   * External item ids to record as dirty. Omit (or pass `[]`) for
   * signal-only drains where the handler derives its own work — e.g. from a
   * provider cursor or a time window — and just needs "run soon, once".
   */
  ids?: string[];
  /**
   * Max ids passed to the handler per pass (default
   * {@link DEFAULT_DRAIN_BATCH_SIZE}). Size this so one pass stays well
   * inside the worker memory and request budget.
   */
  batchSize?: number;
  /**
   * Coalescing delay (default {@link DEFAULT_DRAIN_DELAY_MS}): the drain
   * runs at most this long after the first `scheduleDrain` call of a burst.
   * Later calls never push the pending pass back.
   */
  delayMs?: number;
  /**
   * Per-id failure cap (default {@link DEFAULT_DRAIN_MAX_ATTEMPTS}): after
   * this many failed passes containing the id, it is dropped with a log.
   */
  maxAttempts?: number;
  /**
   * Extra arguments appended after the ids slice when the handler is
   * invoked — `handler(ids, ...handlerArgs)`. Use for per-scope drains
   * (e.g. a per-channel key whose handler needs the channel id). Must be
   * serializable; frozen at the first call of a coalesced burst, so keep
   * them constant for a given `key`.
   */
  handlerArgs?: Serializable[];
};

/**
 * Options embedded in the scheduled wrapper callback. Frozen at the first
 * call of a coalesced burst (later calls' options apply once the pending
 * pass has fired) — in practice pass the same options for a given key.
 */
type PersistedDrainOptions = {
  batchSize: number;
  delayMs: number;
  maxAttempts: number;
  handlerArgs?: Serializable[];
};

/**
 * The narrow surface of Twist/Tool that the drain machinery needs. The
 * indexer covers handler dispatch by method name.
 */
export interface DrainHost {
  callback(fn: (...args: never[]) => unknown, ...extraArgs: Serializable[]): Promise<Callback>;
  scheduleTask(
    key: string,
    callback: Callback,
    options: { runAt: Date; coalesce?: boolean }
  ): Promise<string | void>;
  cancelScheduledTask(key: string): Promise<void>;
  tools: {
    store: {
      get<T>(key: string): Promise<T | null>;
      set(key: string, value: unknown): Promise<void>;
      setMany(entries: [key: string, value: unknown][]): Promise<void>;
      clear(key: string): Promise<void>;
      list(prefix: string): Promise<string[]>;
    };
  };
}

function pendingPrefix(key: string): string {
  return `${DRAIN_STORE_PREFIX}${key}:`;
}

function taskKey(key: string): string {
  return `${DRAIN_TASK_PREFIX}${key}`;
}

/**
 * Resolve and validate the handler: must be a named method reachable on the
 * host instance, so the drain task can dispatch to it by name in a later
 * execution (the same constraint `this.callback(this.method)` has).
 */
function handlerName(host: DrainHost, handler: DrainHandler): string {
  const name = handler.name;
  if (!name) {
    throw new Error(
      "scheduleDrain: handler must be a named method (e.g. this.drainChanges), not an anonymous or arrow function"
    );
  }
  const bound = (host as unknown as Record<string, unknown>)[name];
  if (typeof bound !== "function") {
    throw new Error(
      `scheduleDrain: handler "${name}" is not a method on this twist/tool — pass a method reference like this.${name}`
    );
  }
  return name;
}

/** Implementation behind `this.scheduleDrain(key, handler, options)`. */
export async function scheduleDrainImpl(
  host: DrainHost,
  key: string,
  handler: DrainHandler,
  options?: DrainOptions
): Promise<void> {
  const name = handlerName(host, handler);
  const ids = options?.ids ?? [];
  if (ids.length > 0) {
    // One bulk write per notification batch. Value 0 = no failed attempts
    // yet; re-notifying an id resets its counter (the change is fresh
    // evidence the item is worth fetching).
    await host.tools.store.setMany(
      ids.map((id): [string, unknown] => [`${pendingPrefix(key)}${id}`, 0])
    );
  }
  const persisted: PersistedDrainOptions = {
    batchSize: options?.batchSize ?? DEFAULT_DRAIN_BATCH_SIZE,
    delayMs: options?.delayMs ?? DEFAULT_DRAIN_DELAY_MS,
    maxAttempts: options?.maxAttempts ?? DEFAULT_DRAIN_MAX_ATTEMPTS,
    ...(options?.handlerArgs ? { handlerArgs: options.handlerArgs } : {}),
  };
  await scheduleDrainTask(host, key, name, persisted);
}

/** Schedule (or coalesce into) the pending drain task for `key`. */
async function scheduleDrainTask(
  host: DrainHost,
  key: string,
  name: string,
  options: PersistedDrainOptions
): Promise<void> {
  // The wrapper callback targets the SDK-provided __drainBacklog method on
  // the host, carrying the handler by NAME — no per-call callback row for
  // the handler itself, so coalesced bursts don't grow the callback table.
  const wrapper = await host.callback(
    (host as unknown as { __drainBacklog: (...args: never[]) => unknown })
      .__drainBacklog,
    key,
    name,
    options
  );
  await host.scheduleTask(taskKey(key), wrapper, {
    runAt: new Date(Date.now() + options.delayMs),
    coalesce: true,
  });
}

/**
 * Implementation behind the SDK-internal `__drainBacklog` method — one
 * bounded drain pass. Runs as its own task execution (fresh request budget).
 */
export async function drainBacklogImpl(
  host: DrainHost,
  key: string,
  name: string,
  options: PersistedDrainOptions
): Promise<void> {
  const prefix = pendingPrefix(key);
  const handler = (host as unknown as Record<string, unknown>)[name];
  if (typeof handler !== "function") {
    throw new Error(
      `drain "${key}": handler "${name}" no longer exists on this twist/tool — was it renamed? Re-schedule with the new method.`
    );
  }

  const pendingKeys = (await host.tools.store.list(prefix)).sort();
  const batch = pendingKeys.slice(0, options.batchSize);
  const ids = batch.map((k) => k.slice(prefix.length));
  const handlerArgs = options.handlerArgs ?? [];

  let result: DrainResult;
  try {
    result = await (
      handler as (ids: string[], ...args: unknown[]) => Promise<DrainResult>
    ).call(host, ids, ...handlerArgs);
  } catch (error) {
    // The pass failed: keep the ids (at-least-once) but bump their attempt
    // counters so an unprocessable item is eventually dropped instead of
    // wedging the drain forever. Rethrow so normal task retry semantics
    // (and error reporting) still apply.
    for (const id of ids) {
      try {
        await bumpAttempt(host, key, id, options.maxAttempts);
      } catch {
        // Best-effort: the id simply retries with its previous count.
      }
    }
    throw error;
  }

  // The handler may report a PARTIAL failure — ids from the slice that
  // should be retried on a later pass. Those keep their pending keys with a
  // bumped attempt counter; everything else in the slice is released. Ids
  // marked dirty again while the pass ran keep their fresh keys and are
  // picked up by the next pass.
  const retry = new Set(
    (result?.retry ?? []).filter((id) => ids.includes(id))
  );
  for (const id of ids) {
    if (retry.has(id)) {
      await bumpAttempt(host, key, id, options.maxAttempts);
    } else {
      await host.tools.store.clear(`${prefix}${id}`);
    }
  }

  if (pendingKeys.length > batch.length || retry.size > 0) {
    // Backlog (or retryable failures) remain: schedule a continuation.
    // Coalesces with any pass the next notification schedules, so the
    // backlog strictly shrinks at up to batchSize per delayMs without ever
    // stacking passes.
    await scheduleDrainTask(host, key, name, options);
  }
}

async function bumpAttempt(
  host: DrainHost,
  key: string,
  id: string,
  maxAttempts: number
): Promise<void> {
  const pendingKey = `${pendingPrefix(key)}${id}`;
  const attempts = ((await host.tools.store.get<number>(pendingKey)) ?? 0) + 1;
  if (attempts > maxAttempts) {
    console.error(
      `drain "${key}": giving up on id ${id} after ${attempts - 1} failed passes; its change may be lost until the next notification or self-heal`
    );
    await host.tools.store.clear(pendingKey);
  } else {
    await host.tools.store.set(pendingKey, attempts);
  }
}

/** Implementation behind `this.cancelDrain(key)`. */
export async function cancelDrainImpl(
  host: DrainHost,
  key: string
): Promise<void> {
  await host.cancelScheduledTask(taskKey(key));
  const prefix = pendingPrefix(key);
  for (const pendingKey of await host.tools.store.list(prefix)) {
    await host.tools.store.clear(pendingKey);
  }
}
