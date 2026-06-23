import GoogleContacts from "@plotday/connector-google-contacts";
import {
  type CalendarSyncHost,
  clearBuffersFn,
  resolveCalendarIdFn,
  runCalendarInit,
  runSyncBatch,
} from "@plotday/connector-google-calendar";
import { Connector } from "@plotday/twister";
import type { ToolBuilder } from "@plotday/twister";
import {
  AuthProvider,
  Integrations,
  type Authorization,
  type AuthToken,
  type Channel,
  type SyncContext,
} from "@plotday/twister/tools/integrations";
import { Network } from "@plotday/twister/tools/network";

import { GOOGLE_SCOPES } from "./scopes";
import { composeChannels, resolveProductForChannelId } from "./compose";
import { parse } from "./product-channel";
import { PRODUCTS_BY_KEY } from "./products/product";

/**
 * Combined Google connector: Mail, Calendar, Tasks, and Contacts under a
 * single OAuth grant. Calendar channels are handled directly by this class
 * (with `calendar:` key namespacing); other products delegate to their
 * respective product modules.
 */
export class Google extends Connector<Google> {
  readonly provider = AuthProvider.Google;

  readonly dynamicLinkTypes = true;

  readonly scopes = GOOGLE_SCOPES;

  readonly channelNoun = { singular: "channel", plural: "channels" };

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      network: build(Network, {
        urls: ["https://www.googleapis.com/calendar/*"],
      }),
      googleContacts: build(GoogleContacts),
    };
  }

  async getChannels(
    _auth: Authorization | null,
    token: AuthToken | null
  ): Promise<Channel[]> {
    if (!token) return [];
    return composeChannels(Object.values(PRODUCTS_BY_KEY), token);
  }

  async onChannelEnabled(
    channel: Channel,
    context?: SyncContext
  ): Promise<void> {
    const { product: productKey, rawId } = parse(channel.id);

    if (productKey === "calendar") {
      await this.onCalendarChannelEnabled(rawId, context);
      return;
    }

    const product = resolveProductForChannelId(
      Object.values(PRODUCTS_BY_KEY),
      channel.id
    );
    if (!product) return;
    await product.onEnable(rawId, context);
  }

  async onChannelDisabled(channel: Channel): Promise<void> {
    const product = resolveProductForChannelId(
      Object.values(PRODUCTS_BY_KEY),
      channel.id
    );
    if (!product) return;
    const { rawId } = parse(channel.id);
    await product.onDisable(rawId);
  }

  // ---------------------------------------------------------------------------
  // Host wrapper (prefixes all storage keys with "calendar:")
  // ---------------------------------------------------------------------------

  /**
   * Public set proxy so makeCalendarHost() can wrap `this` through a
   * CalendarSyncHost interface (which requires public methods).
   */
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  _calendarHostSet(key: string, value: any): Promise<void> {
    return this.set(`calendar:${key}`, value);
  }
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  _calendarHostGet<T = any>(key: string): Promise<T | null> {
    return this.get<any>(`calendar:${key}`);
  }
  _calendarHostClear(key: string): Promise<void> {
    return this.clear(`calendar:${key}`);
  }

  /**
   * Returns a CalendarSyncHost that namespaces every storage key under
   * `calendar:` so calendar state can't collide with mail/tasks keys.
   *
   * The store.list proxy also strips the `calendar:` prefix from results
   * so the extracted functions see consistent un-prefixed keys.
   */
  private makeCalendarHost(): CalendarSyncHost {
    const self = this;
    return {
      set: (key, value) => self._calendarHostSet(key, value),
      get: <T>(key: string) => self._calendarHostGet<T>(key),
      clear: (key) => self._calendarHostClear(key),
      tools: {
        integrations: self.tools.integrations as any,
        googleContacts: self.tools.googleContacts,
        store: {
          acquireLock: (key, ttlMs) =>
            self.tools.store.acquireLock(`calendar:${key}`, ttlMs),
          releaseLock: (key) =>
            self.tools.store.releaseLock(`calendar:${key}`),
          /**
           * Lists prefixed keys and strips the `calendar:` prefix from
           * the returned paths so callers can use them as-is with
           * host.get/host.clear (which will re-add the prefix).
           */
          list: async (prefix) => {
            const keys = await self.tools.store.list(`calendar:${prefix}`);
            return keys.map((k) =>
              k.startsWith("calendar:") ? k.slice("calendar:".length) : k
            );
          },
        },
      },
    };
  }

  // ---------------------------------------------------------------------------
  // Calendar lifecycle methods (dispatched callbacks — must live on this class)
  // ---------------------------------------------------------------------------

  /**
   * Pre-init logic for a calendar channel: recovery state wipe, history-min
   * window check, then queue `calendarInit` as a task.
   */
  private async onCalendarChannelEnabled(
    rawId: string,
    context?: SyncContext
  ): Promise<void> {
    const host = this.makeCalendarHost();

    // Resolve "primary" to the actual calendar id for recovery clearing.
    // Mirrors what GoogleCalendar.onChannelEnabled does.
    const resolvedCalendarId = await resolveCalendarIdFn(host, rawId);

    if (context?.recovering) {
      await host.clear(`last_sync_token_${resolvedCalendarId}`);
      await host.clear(`last_sync_token_${rawId}`);
      await host.clear(`sync_state_${resolvedCalendarId}`);
      await host.tools.store.releaseLock(`sync_${resolvedCalendarId}`);
      await clearBuffersFn(host, resolvedCalendarId);
    } else if (context?.syncHistoryMin) {
      const key = `sync_history_min_${rawId}`;
      const stored = await host.get<string>(key);
      if (stored && new Date(stored) <= context.syncHistoryMin) {
        return; // Already synced with equal or earlier history min
      }
      await host.set(key, context.syncHistoryMin.toISOString());
    }

    const initCallback = await this.callback(this.calendarInit, rawId);
    await this.runTask(initCallback);
  }

  /**
   * Initializes a calendar channel: resolves the calendar ID, acquires the
   * sync lock, sets the initial SyncState, and queues the first batch.
   *
   * NOTE: Watch setup (webhooks) is intentionally omitted — the combined
   * connector does not yet re-home the incremental/webhook path. This will be
   * added in a future phase.
   */
  async calendarInit(calendarId: string): Promise<void> {
    const host = this.makeCalendarHost();
    const result = await runCalendarInit(host, calendarId);
    if ("done" in result) return;

    // TODO Phase: incremental watch not yet re-homed from GoogleCalendar.
    // Watch setup (setupCalendarWatch / onCalendarWebhook) will be wired here
    // once the webhook/incremental path is migrated to the combined connector.

    const { resolvedCalendarId, batchNumber, mode, initialSync } = result.next;
    const syncCallback = await this.callback(
      this.calendarSyncBatch,
      batchNumber,
      mode,
      resolvedCalendarId,
      initialSync
    );
    await this.runTask(syncCallback);
  }

  /**
   * Processes one batch of calendar events and schedules the next batch.
   * Delegates to {@link runSyncBatch} with the `calendar:` namespaced host.
   */
  async calendarSyncBatch(
    batchNumber: number,
    mode: "full" | "incremental",
    calendarId: string,
    initialSync?: boolean
  ): Promise<void> {
    const host = this.makeCalendarHost();
    const result = await runSyncBatch(
      host,
      batchNumber,
      mode,
      calendarId,
      initialSync ?? false
    );
    if ("done" in result) return;
    const nextCallback = await this.callback(
      this.calendarSyncBatch,
      result.next.batchNumber,
      result.next.mode,
      calendarId,
      initialSync ?? false
    );
    await this.runTask(nextCallback);
  }
}

export default Google;
