import {
  type Link,
  type NewLinkWithNotes,
  type Actor,
} from "@plotday/twister";
import { Connector, type CreateLinkDraft } from "@plotday/twister/connector";
import type { ToolBuilder } from "@plotday/twister/tool";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  Integrations,
  type Channel,
  type SyncContext,
} from "@plotday/twister/tools/integrations";
import { Network } from "@plotday/twister/tools/network";
import { Tasks } from "@plotday/twister/tools/tasks";

import { TASKS_LINK_TYPES, getTasksChannels } from "./channels";
import {
  type TasksSyncHost,
  POLL_INTERVAL_MS,
  POLL_RECURRING_INTERVAL_MS,
  onChannelDisabledFn,
  onChannelEnabledFn,
  onCreateLinkFn,
  onLinkUpdatedFn,
  periodicSyncBatchFn,
  periodicSyncFn,
  syncBatchFn,
} from "./sync";

/**
 * Google Tasks connector
 *
 * Syncs Google Tasks lists and tasks with Plot threads.
 * Uses polling (5-minute intervals) since Google Tasks API
 * does not support webhooks.
 *
 * The sync, polling, and write-back logic lives in `./sync` as standalone
 * functions over a {@link TasksSyncHost}; this class is a thin connector that
 * builds a host from `this`, owns all scheduling, and delegates the rest.
 */
export class GoogleTasks extends Connector<GoogleTasks> {
  static readonly PROVIDER = AuthProvider.Google;
  static readonly SCOPES = ["https://www.googleapis.com/auth/tasks"];

  readonly provider = AuthProvider.Google;
  readonly channelNoun = { singular: "list", plural: "lists" };
  readonly autoEnableNewChannelsByDefault = true;
  readonly scopes = GoogleTasks.SCOPES;
  readonly access = [
    "Reads and updates your Google Tasks so they stay in sync with Plot",
    "Creates and completes tasks you change in Plot",
  ];
  readonly linkTypes = TASKS_LINK_TYPES;

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      network: build(Network, { urls: ["https://tasks.googleapis.com/*"] }),
      tasks: build(Tasks),
    };
  }

  // ---------------------------------------------------------------------------
  // Host wrapper + public state delegators
  //
  // The Connector base class exposes set/get/clear (and `id`) as `protected`,
  // but TasksSyncHost requires them as public. We bridge this via a host object
  // that delegates through the public wrapper methods below. The host's
  // `scheduler` section routes back to this connector's own scheduling methods
  // (which remain here so they reference `this.callback`/`this.tools.tasks.*`).
  // ---------------------------------------------------------------------------

  /** Public set wrapper so the host object can expose it. */
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  _hostSet(key: string, value: any): Promise<void> {
    return this.set(key, value);
  }
  /** Public get wrapper so the host object can expose it. */
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  _hostGet<T = any>(key: string): Promise<T | null> {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    return this.get<any>(key);
  }
  /** Public clear wrapper so the host object can expose it. */
  _hostClear(key: string): Promise<void> {
    return this.clear(key);
  }

  /**
   * Returns a TasksSyncHost backed by this connector instance.
   * Passes through all tool access, exposes set/get/clear + id as public
   * members, and binds the scheduler section to this connector's own methods.
   */
  private makeHost(): TasksSyncHost {
    const self = this;
    return {
      id: self.id,
      set: (key, value) => self._hostSet(key, value),
      get: <T>(key: string) => self._hostGet<T>(key),
      clear: (key) => self._hostClear(key),
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      tools: self.tools as any,
      scheduler: {
        queueSyncBatch: (listId) => self.queueSyncBatch(listId),
        queuePeriodicSyncBatch: (listId) => self.queuePeriodicSyncBatch(listId),
        schedulePeriodicSync: (listId) => self.schedulePeriodicSync(listId),
        cancelScheduledTask: (key) => self.tools.tasks.cancelScheduledTask(key),
      },
    };
  }

  override async activate(context: {
    auth?: Authorization;
    actor?: Actor;
  }): Promise<void> {
    if (context.actor) {
      await this.set("auth_actor_id", context.actor.id);
    }
  }

  /**
   * Returns available Google Tasks lists as channels.
   */
  async getChannels(
    _auth: Authorization,
    token: AuthToken
  ): Promise<Channel[]> {
    return getTasksChannels(token);
  }

  /**
   * Called when a channel (task list) is enabled.
   * Starts initial sync and schedules periodic polling.
   */
  async onChannelEnabled(channel: Channel, context?: SyncContext): Promise<void> {
    const result = await onChannelEnabledFn(this.makeHost(), channel.id, {
      syncHistoryMin: context?.syncHistoryMin,
      recovering: context?.recovering,
    });
    if ("skip" in result) return;

    await this.queueSyncBatch(result.start.listId);
    await this.schedulePeriodicSync(result.start.listId);
  }

  /**
   * Called when a channel is disabled.
   * Stops periodic sync and removes state.
   */
  async onChannelDisabled(channel: Channel): Promise<void> {
    await onChannelDisabledFn(this.makeHost(), channel.id);
  }

  // ---------------------------------------------------------------------------
  // Scheduling — stays on the connector
  // ---------------------------------------------------------------------------

  /** Queue the per-list initial backfill batch as a fresh task. */
  private async queueSyncBatch(listId: string): Promise<void> {
    const callback = await this.callback(this.syncBatch, listId);
    await this.tools.tasks.runTask(callback);
  }

  /** Queue the next periodic-sync page as a fresh task. */
  private async queuePeriodicSyncBatch(listId: string): Promise<void> {
    const callback = await this.callback(this.periodicSyncBatch, listId);
    await this.tools.tasks.runTask(callback);
  }

  /**
   * Schedule (or reschedule) the recurring poll for a task list. Keyed
   * singleton: re-scheduling under `poll:<listId>` atomically replaces any
   * pending poll, so a redundant entry into the setup path (onChannelEnabled
   * re-dispatch on auto-enable / recovery) can never stack a second parallel
   * poll chain. Each list keeps its own independent loop.
   */
  private async schedulePeriodicSync(listId: string): Promise<void> {
    const syncCallback = await this.callback(this.periodicSync, listId);
    await this.tools.tasks.scheduleRecurring(`poll:${listId}`, syncCallback, {
      intervalMs: POLL_RECURRING_INTERVAL_MS,
      firstRunAt: new Date(Date.now() + POLL_INTERVAL_MS),
    });
  }

  // ---------------------------------------------------------------------------
  // Sync batches — delegate to extracted state machine, own the scheduling
  // ---------------------------------------------------------------------------

  /**
   * Process a batch of tasks from a Google Tasks list. Delegates to
   * {@link syncBatchFn} and schedules the next batch when more pages remain.
   */
  private async syncBatch(listId: string): Promise<void> {
    const result = await syncBatchFn(this.makeHost(), listId);
    if ("done" in result) return;
    await this.queueSyncBatch(result.next.listId);
  }

  /**
   * Periodic sync entry point: starts a new cycle and hands off to
   * {@link periodicSyncBatch} so each page is processed in its own task with a
   * fresh runtime request budget.
   */
  private async periodicSync(listId: string): Promise<void> {
    const start = await periodicSyncFn(this.makeHost(), listId);
    if (!start) return;
    await this.queuePeriodicSyncBatch(listId);
  }

  /**
   * Process a single page of incremental updates and either chain to the next
   * page or finish the cycle and reschedule the next periodic run. Delegates
   * to {@link periodicSyncBatchFn}.
   */
  private async periodicSyncBatch(listId: string): Promise<void> {
    const result = await periodicSyncBatchFn(this.makeHost(), listId);
    if ("done" in result) return;
    if ("next" in result) {
      await this.queuePeriodicSyncBatch(result.next.listId);
      return;
    }
    await this.schedulePeriodicSync(result.reschedule.listId);
  }

  // ---------------------------------------------------------------------------
  // Framework callbacks — outbound write-back
  // ---------------------------------------------------------------------------

  /**
   * Create a new Google Task from a Plot thread. Delegates to
   * {@link onCreateLinkFn}.
   */
  async onCreateLink(
    draft: CreateLinkDraft
  ): Promise<NewLinkWithNotes | null> {
    return onCreateLinkFn(this.makeHost(), draft);
  }

  /**
   * Write back link status changes to Google Tasks. Delegates to
   * {@link onLinkUpdatedFn}.
   */
  async onLinkUpdated(link: Link): Promise<void> {
    await onLinkUpdatedFn(this.makeHost(), link);
  }
}

export default GoogleTasks;
