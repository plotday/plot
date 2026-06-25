import { Connector } from "@plotday/twister";
import type { Actor, ToolBuilder } from "@plotday/twister";
import {
  AuthProvider,
  Integrations,
  type Authorization,
  type AuthToken,
  type Channel,
  type SyncContext,
} from "@plotday/twister/tools/integrations";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";
import { Files } from "@plotday/twister/tools/files";
import {
  type OutlookMailSyncHost,
  SELF_HEAL_INTERVAL_MS,
  addEnabledChannelFn,
  removeEnabledChannelFn,
  getEnabledChannelsFn,
  ensureMailboxSubscriptionFn,
  setupMailboxSubscriptionFn,
  teardownMailboxSubscriptionFn,
  renewMailboxSubscriptionFn,
  selfHealCheckFn,
  recoverMailboxDeliveryFn,
  requeueInitialSyncFn,
  initialSyncBatchFn,
  incrementalSyncBatchFn,
  onOutlookMailWebhookFn,
  getMailboxRenewalSchedule,
  type InitialSyncState,
} from "@plotday/connector-outlook-mail";

import { OUTLOOK_SCOPES, PRODUCTS } from "./scopes";
import { composeChannels } from "./compose";
import { parse } from "./product-channel";
import { PRODUCTS_BY_KEY } from "./products/product";

/**
 * Combined Outlook (Microsoft Graph) connector: Mail, Calendar, and Contacts
 * under a single OAuth grant.
 *
 * All products run through one Microsoft account. Channel ids are namespaced
 * `"<product>:<rawId>"` (see {@link parse} / `./product-channel`) so each
 * product's storage and lifecycle stay isolated. Mail is handled directly by
 * this class via a `mail:`-namespaced {@link OutlookMailSyncHost} that wraps
 * `this` and drives the extracted `@plotday/connector-outlook-mail` sync
 * functions. Calendar and Contacts are wired in later phases (E1/F1).
 *
 * **Required OAuth Scopes** (declared as optional scope groups in
 * {@link OUTLOOK_SCOPES}; per-product availability is derived from the granted
 * `token.scopes`):
 * - Mail: `Mail.ReadWrite`, `Mail.Send`
 * - Calendar: `Calendars.ReadWrite`
 * - Contacts: `People.Read`, `Contacts.Read`
 */
export class Outlook extends Connector<Outlook> {
  static readonly handleReplies = true;

  readonly provider = AuthProvider.Microsoft;

  readonly dynamicLinkTypes = true;

  readonly scopes = OUTLOOK_SCOPES;

  /**
   * Per-product metadata for the combined-connection setup/status UX. Each
   * entry's `scopeGroupId` matches an `OptionalScopeGroup.id` in OUTLOOK_SCOPES,
   * so the API can derive per-product enablement from granted scopes +
   * enabled channels.
   */
  readonly products = PRODUCTS;

  readonly channelNoun = { singular: "channel", plural: "channels" };

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      network: build(Network, { urls: ["https://graph.microsoft.com/*"] }),
      files: build(Files),
    };
  }

  /**
   * Records the connecting user's actor id so Mail sync can attribute synced
   * threads to the account owner. Stored under the Mail product's key
   * namespace, matching what the extracted sync reads via its host.
   */
  override async activate(context: {
    auth: Authorization;
    actor: Actor;
  }): Promise<void> {
    await this.makeMailHost().set("auth_actor_id", context.actor.id);
  }

  async getChannels(
    _auth: Authorization | null,
    token: AuthToken | null
  ): Promise<Channel[]> {
    if (!token) return [];
    return composeChannels(Object.values(PRODUCTS_BY_KEY), token);
  }

  /**
   * Durable recovery backstop, run on every deploy. Re-asserts recurring
   * maintenance for a healthy mailbox and re-establishes (plus backfills) a
   * stranded one. See {@link recoverMailboxDeliveryFn}.
   */
  override async upgrade(): Promise<void> {
    await recoverMailboxDeliveryFn(this.makeMailHost());
  }

  async onChannelEnabled(
    channel: Channel,
    context?: SyncContext
  ): Promise<void> {
    const { product: productKey, rawId } = parse(channel.id);

    if (productKey === "mail") {
      await this.onMailChannelEnabled(rawId, context);
      return;
    }

    // TODO(E1/F1): wire calendar/contacts. Calendar's product.onEnable throws
    // by design (handled here, not in the product module), and Contacts has no
    // import (enabling only grants enrichment scopes Mail reads via
    // token.scopes), so leave both as explicit no-op stubs until E1/F1 fill in
    // the calendar:/contacts: dispatch the same way mail is wired above.
    if (productKey === "calendar" || productKey === "contacts") {
      return;
    }
  }

  async onChannelDisabled(channel: Channel): Promise<void> {
    const { product: productKey, rawId } = parse(channel.id);

    if (productKey === "mail") {
      await this.stopMailSync(rawId);
      return;
    }

    // TODO(E1/F1): wire calendar/contacts teardown.
    if (productKey === "calendar" || productKey === "contacts") {
      return;
    }
  }

  // ===========================================================================
  // Mail (Microsoft Graph) — mirrors @plotday/connector-outlook-mail. All
  // storage keys + locks are namespaced under "mail:"; scheduling (callback /
  // runTask / scheduleRecurring / cancelScheduledTask) is owned here and routed
  // back through the host's scheduler boundary.
  // ===========================================================================

  /** Public set proxy so makeMailHost() can wrap `this` (host needs public). */
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  _mailHostSet(key: string, value: any): Promise<void> {
    return this.set(`mail:${key}`, value);
  }
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  _mailHostGet<T = any>(key: string): Promise<T | null> {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    return this.get<any>(`mail:${key}`);
  }
  _mailHostClear(key: string): Promise<void> {
    return this.clear(`mail:${key}`);
  }

  /**
   * Returns an OutlookMailSyncHost that namespaces every storage key + lock
   * under "mail:" and routes the scheduler section back to this connector's own
   * mail* methods (which own this.callback / runTask / scheduleRecurring /
   * cancelScheduledTask). Durable task keys (mailbox-subscription-renewal,
   * mailbox-self-heal) are NOT prefixed — they're per-instance task keys (one
   * mailbox per connection) and the extracted functions pass those raw keys to
   * cancelScheduledTask.
   */
  private makeMailHost(): OutlookMailSyncHost {
    const self = this;
    return {
      id: self.id,
      set: (key, value) => self._mailHostSet(key, value),
      get: <T>(key: string) => self._mailHostGet<T>(key),
      clear: (key) => self._mailHostClear(key),
      tools: {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        integrations: self.tools.integrations as any,
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        files: self.tools.files as any,
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        network: self.tools.network as any,
        store: {
          acquireLock: (key, ttlMs) =>
            self.tools.store.acquireLock(`mail:${key}`, ttlMs),
          releaseLock: (key) => self.tools.store.releaseLock(`mail:${key}`),
          list: async (prefix) => {
            const keys = await self.tools.store.list(`mail:${prefix}`);
            return keys.map((k) =>
              k.startsWith("mail:") ? k.slice("mail:".length) : k
            );
          },
        },
      },
      scheduler: {
        onOutlookMailWebhook: self.onOutlookMailWebhook,
        setupMailboxSubscription: () => self.mailSetupSubscription(),
        renewMailboxSubscription: () => self.renewMailboxSubscription(),
        scheduleMailboxRenewal: (expiration) =>
          self.mailScheduleRenewal(expiration),
        scheduleSelfHealCheck: () => self.mailScheduleSelfHeal(),
        cancelScheduledTask: (key) => self.cancelScheduledTask(key),
        queueIncrementalSync: (messageIds) =>
          self.mailQueueIncrementalSync(messageIds),
        queueRenewSubscription: () => self.mailQueueRenewSubscription(),
        requeueInitialSync: (channelId) => self.mailRequeueInitialSync(channelId),
      },
    };
  }

  /**
   * Pre-init for a mail channel (raw Graph folder id): recovery / history-min
   * handling, register the channel, then queue the per-channel initial backfill
   * + the idempotent mailbox-wide subscription setup. Mirrors
   * OutlookMail.onChannelEnabled.
   */
  private async onMailChannelEnabled(
    rawId: string,
    context?: SyncContext
  ): Promise<void> {
    const host = this.makeMailHost();
    const syncHistoryMin = context?.syncHistoryMin;

    if (context?.recovering) {
      // Recovery dispatch after re-auth: drop the per-channel cursors so this
      // channel re-walks its folder and the delta baseline reseeds.
      await host.clear(`initial_state_${rawId}`);
      await host.clear(`delta_${rawId}`);
    } else if (syncHistoryMin) {
      const storedMin = await host.get<string>(`sync_history_min_${rawId}`);
      if (storedMin && new Date(storedMin) <= syncHistoryMin) {
        return;
      }
      await host.set(`sync_history_min_${rawId}`, syncHistoryMin.toISOString());
    }

    await addEnabledChannelFn(host, rawId);

    // observeOnly: auto-observed (a Plot thread was composed into this folder),
    // not explicitly enabled — register the subscription but skip historical
    // backfill.
    if (!context?.observeOnly) {
      const initialState: InitialSyncState = {
        lastSyncTime: syncHistoryMin ?? undefined,
      };
      await host.set(`initial_state_${rawId}`, initialState);
      const initialCallback = await this.callback(
        this.initialSyncBatch,
        rawId,
        1
      );
      await this.runTask(initialCallback);
    }

    // Queue mailbox-wide subscription setup as a separate task to avoid
    // blocking the HTTP response. ensureMailboxSubscription is idempotent.
    const subscriptionCallback = await this.callback(
      this.ensureMailboxSubscription
    );
    await this.runTask(subscriptionCallback);
  }

  /** Teardown for a mail channel; mirrors OutlookMail.onChannelDisabled. */
  private async stopMailSync(rawId: string): Promise<void> {
    const host = this.makeMailHost();
    await removeEnabledChannelFn(host, rawId);
    await host.clear(`initial_state_${rawId}`);
    await host.clear(`sync_history_min_${rawId}`);
    await host.clear(`delta_${rawId}`);

    // Tear the mailbox subscription down only if this was the last enabled
    // folder. The next onChannelEnabled rebuilds it.
    const enabled = await getEnabledChannelsFn(host);
    if (enabled.size === 0) {
      await teardownMailboxSubscriptionFn(host);
    }
  }

  // --- Mail dispatched callbacks (must live on this class) -------------------

  /** Per-channel initial backfill; schedules the next batch when more remain. */
  async initialSyncBatch(channelId: string, batchNumber: number): Promise<void> {
    const result = await initialSyncBatchFn(
      this.makeMailHost(),
      channelId,
      batchNumber
    );
    if ("done" in result) return;
    const next = await this.callback(
      this.initialSyncBatch,
      channelId,
      result.next.batchNumber
    );
    await this.runTask(next);
  }

  /** Mailbox-wide incremental sync over a set of notified message ids. */
  async incrementalSyncBatch(messageIds: string[]): Promise<void> {
    await incrementalSyncBatchFn(this.makeMailHost(), messageIds);
  }

  /** Idempotently (re)establish the mailbox subscription + webhook. */
  async ensureMailboxSubscription(): Promise<void> {
    await ensureMailboxSubscriptionFn(this.makeMailHost());
  }

  private async mailSetupSubscription(): Promise<void> {
    await setupMailboxSubscriptionFn(this.makeMailHost());
  }

  private async mailScheduleRenewal(expiration: Date): Promise<void> {
    const renewalCallback = await this.callback(this.renewMailboxSubscription);
    await this.scheduleRecurring(
      "mailbox-subscription-renewal",
      renewalCallback,
      getMailboxRenewalSchedule(expiration)
    );
  }

  async renewMailboxSubscription(): Promise<void> {
    await renewMailboxSubscriptionFn(this.makeMailHost());
  }

  async selfHealCheck(): Promise<void> {
    await selfHealCheckFn(this.makeMailHost());
  }

  private async mailScheduleSelfHeal(): Promise<void> {
    const callback = await this.callback(this.selfHealCheck);
    await this.scheduleRecurring("mailbox-self-heal", callback, {
      intervalMs: SELF_HEAL_INTERVAL_MS,
    });
  }

  private async mailQueueIncrementalSync(messageIds: string[]): Promise<void> {
    const callback = await this.callback(
      this.incrementalSyncBatch,
      messageIds
    );
    await this.runTask(callback);
  }

  private async mailQueueRenewSubscription(): Promise<void> {
    const callback = await this.callback(this.renewMailboxSubscription);
    await this.runTask(callback);
  }

  /**
   * Re-queue a fresh full backfill of one folder, dropping stale cursors, then
   * schedule the first initial batch. Routed from `host.scheduler` so recovery
   * (run from {@link upgrade}) keeps scheduling on the connector.
   */
  private async mailRequeueInitialSync(channelId: string): Promise<void> {
    const { scheduleInitialBatch } = await requeueInitialSyncFn(
      this.makeMailHost(),
      channelId
    );
    const initial = await this.callback(
      this.initialSyncBatch,
      scheduleInitialBatch.channelId,
      1
    );
    await this.runTask(initial);
  }

  // --- Mail framework callback: webhook -------------------------------------
  // The runtime dispatches this by its framework name. It delegates to the
  // extracted Graph change-notification handler and queues the follow-up tasks
  // the returned descriptor requests.

  /**
   * Graph change-notification handler (synchronous webhook). Echoes the
   * validation handshake, verifies clientState, then queues subscription
   * renewal and/or an incremental sync over the notified message ids.
   */
  async onOutlookMailWebhook(
    request: WebhookRequest
  ): Promise<string | void> {
    const result = await onOutlookMailWebhookFn(this.makeMailHost(), request);
    if ("validationToken" in result) {
      return result.validationToken;
    }
    if ("done" in result) return;
    if (result.queueRenewSubscription) {
      await this.mailQueueRenewSubscription();
    }
    if (result.queueIncrementalSync) {
      await this.mailQueueIncrementalSync(result.messageIds);
    }
  }
}

export default Outlook;
