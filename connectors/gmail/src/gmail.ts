import {
  Connector,
  type NoteWriteBackResult,
  type ToolBuilder,
  Tag,
} from "@plotday/twister";
import type { Actor, ActorId, Note, Thread, Link } from "@plotday/twister/plot";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  type Channel,
  Integrations,
  type SyncContext,
} from "@plotday/twister/tools/integrations";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";

import {
  GOOGLE_PEOPLE_SCOPES,
  enrichLinkContactsFromGoogle,
} from "@plotday/connector-google-contacts";

import {
  GmailApi,
  type GmailThread,
  type SyncState,
  buildReplyMessage,
  getHeader,
  parseEmailAddresses,
  syncGmailChannel,
  syncGmailMailboxIncremental,
  transformGmailThread,
} from "./gmail-api";

/**
 * Persisted mailbox-wide watch state. There is exactly one Gmail watch per
 * mailbox — calling `users.watch` twice replaces the previous registration —
 * so this state is per-twist-instance, not per-channel.
 */
type MailboxWebhookState = {
  topicName: string;
  historyId: string;
  expiration: Date;
  created: string;
};

/** Persisted per-channel initial-backfill cursor. */
type InitialSyncState = {
  pageToken?: string;
  lastSyncTime?: Date;
};

/**
 * Per-channel system labels we route through, in priority order (most
 * specific first). Threads with custom user labels are handled separately
 * (custom labels always win over system labels).
 */
const SYSTEM_LABEL_ORDER = ["STARRED", "IMPORTANT", "INBOX", "SENT", "DRAFT"];

type MessageChannel = {
  id: string;
  name: string;
  description: string | null;
  primary: boolean;
};

type MessageSyncOptions = {
  timeMin?: Date;
};

/**
 * Gmail integration source implementing the MessagingSource interface.
 *
 * Supports inbox, labels, and search filters as channels.
 * Auth is managed declaratively via provider config in build() and
 * handled through the twist edit modal.
 *
 * **Required OAuth Scope:**
 * - `https://www.googleapis.com/auth/gmail.modify` - Read messages, modify labels, send replies
 *
 * `gmail.modify` is a superset that grants all read/write operations except
 * permanent delete, so it covers reading threads, archiving, label changes,
 * and sending replies without needing `gmail.readonly` or `gmail.send`.
 */
export class Gmail extends Connector<Gmail> {
  static readonly PROVIDER = AuthProvider.Google;
  static readonly handleReplies = true;
  static readonly SCOPES = ["https://www.googleapis.com/auth/gmail.modify"];

  readonly provider = AuthProvider.Google;
  // Merge in People API scopes so we can enrich email-only contacts (Gmail
  // headers carry name + address but no avatar) with photos from the user's
  // Google Contacts and "other contacts" — without requiring the separate
  // Google Contacts connector to be installed.
  readonly scopes = Integrations.MergeScopes(
    Gmail.SCOPES,
    GOOGLE_PEOPLE_SCOPES,
  );
  readonly linkTypes = [
    {
      type: "email",
      label: "Email",
      logo: "https://api.iconify.design/logos/google-gmail.svg",
      logoMono: "https://api.iconify.design/simple-icons/gmail.svg",
      statuses: [
        { status: "inbox", label: "Inbox" },
        { status: "starred", label: "Starred", tag: Tag.Star, todo: true },
        { status: "archived", label: "Archived", tag: Tag.Done, done: true },
      ],
    },
  ];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      network: build(Network, {
        urls: ["https://gmail.googleapis.com/gmail/v1/*"],
      }),
    };
  }

  override async activate(context: { auth: Authorization; actor: Actor }): Promise<void> {
    await this.set("auth_actor_id", context.actor.id);
  }

  /**
   * Migration from per-channel watches to a single mailbox-wide watch.
   *
   * Old layout (per-channel):
   *   - `channel_webhook_${id}`, `watch_renewal_task_${id}`, `sync_state_${id}`,
   *     `sync_enabled_${id}`
   * New layout (per-twist-instance):
   *   - `mailbox_webhook`, `mailbox_renewal_task`, `incremental_state`,
   *     `enabled_channels`, plus `initial_state_${id}` for in-flight backfills
   *
   * The Twist runtime API doesn't let connectors enumerate stored keys, so we
   * probe the system labels we know users can enable. Users with custom
   * Gmail labels enabled (e.g. `Label_14`) will need to re-toggle them after
   * this upgrade — without `list()` we can't discover their IDs.
   */
  override async upgrade(): Promise<void> {
    // Already migrated? `mailbox_webhook` is the canonical sentinel.
    const already = await this.get<MailboxWebhookState>("mailbox_webhook");
    if (already) return;

    // Stop whatever per-channel watch was last active. Gmail allows only
    // one watch per mailbox, so a single stopWatch() call covers all of
    // them — but the call needs an authed API client.
    const stopApi = await this.findAnyAuthApi();
    if (stopApi) {
      try {
        await stopApi.stopWatch();
      } catch {
        // Best effort — old watch may have already expired.
      }
    }

    // Probe known system labels for old per-channel state and migrate.
    let migratedAny = false;
    for (const labelId of SYSTEM_LABEL_ORDER) {
      const oldWebhook = await this.get<{ topicName?: string }>(
        `channel_webhook_${labelId}`
      );
      const oldEnabled = await this.get<boolean>(`sync_enabled_${labelId}`);
      const oldSyncState = await this.get<SyncState>(`sync_state_${labelId}`);
      const oldRenewalTask = await this.get<string>(
        `watch_renewal_task_${labelId}`
      );

      if (
        !oldWebhook &&
        !oldEnabled &&
        !oldSyncState &&
        !oldRenewalTask
      ) {
        continue;
      }

      // Channel was enabled (presence of any old per-channel key counts).
      if (oldEnabled || oldWebhook) {
        await this.addEnabledChannel(labelId);
        migratedAny = true;
      }

      // Carry over any in-flight initial-backfill cursor.
      if (oldSyncState?.pageToken) {
        await this.set<InitialSyncState>(`initial_state_${labelId}`, {
          pageToken: oldSyncState.pageToken,
          lastSyncTime: oldSyncState.lastSyncTime,
        });
        // Resume the backfill under the new callback.
        const next = await this.callback(this.initialSyncBatch, labelId, 1);
        await this.runTask(next);
      }

      // Cancel old per-channel renewal task.
      if (oldRenewalTask) {
        try {
          await this.cancelTask(oldRenewalTask);
        } catch {
          // Task may have already executed.
        }
        await this.clear(`watch_renewal_task_${labelId}`);
      }

      // Clean up old per-channel topic. The topic still receives no
      // notifications (Gmail's mailbox watch points elsewhere now), but
      // leaving it dangling wastes Pub/Sub resources.
      if (oldWebhook?.topicName) {
        try {
          await this.tools.network.deleteWebhook(oldWebhook.topicName);
        } catch (error) {
          console.warn(
            `Failed to delete old per-channel webhook ${labelId}:`,
            error
          );
        }
      }
      await this.clear(`channel_webhook_${labelId}`);
      await this.clear(`sync_state_${labelId}`);
      await this.clear(`sync_enabled_${labelId}`);
    }

    if (migratedAny) {
      await this.setupMailboxWebhook();
    }
  }

  private async findAnyAuthApi(): Promise<GmailApi | null> {
    // Try known system labels and any already-migrated channels in the new
    // enabled_channels list. Per-channel auth is just the Google account
    // token, so any channelId works.
    const candidates = new Set<string>(SYSTEM_LABEL_ORDER);
    for (const id of await this.getEnabledChannels()) candidates.add(id);
    for (const channelId of candidates) {
      try {
        const token = await this.tools.integrations.get(channelId);
        if (token?.token) return new GmailApi(token.token);
      } catch {
        // Channel unknown to integrations — skip.
      }
    }
    return null;
  }

  async getChannels(
    _auth: Authorization,
    token: AuthToken
  ): Promise<Channel[]> {
    const api = new GmailApi(token.token);
    const labels = await api.getLabels();
    return labels
      .filter(
        (l: any) =>
          l.type !== "system" ||
          ["INBOX", "SENT", "DRAFT", "IMPORTANT", "STARRED"].includes(l.id)
      )
      .map((l: any) => ({ id: l.id, title: l.name }));
  }

  async onChannelEnabled(channel: Channel, context?: SyncContext): Promise<void> {
    const syncHistoryMin = context?.syncHistoryMin;
    if (context?.recovering) {
      // Recovery dispatch after re-auth: drop the per-channel initial
      // cursor so this channel re-walks its label. Don't touch
      // `incremental_state` here — the mailbox-wide cursor is shared
      // across all channels, and incrementalSyncBatch already self-heals
      // a stale (>7 day) historyId via the 404 → reseed path.
      await this.clear(`initial_state_${channel.id}`);
    } else if (syncHistoryMin) {
      // Skip when stored window is already at least as wide. Bypassed on
      // recovery so the recovery pass re-walks even when the window
      // hasn't widened.
      const storedMin = await this.get<string>(`sync_history_min_${channel.id}`);
      if (storedMin && new Date(storedMin) <= syncHistoryMin) {
        return;
      }
      await this.set(`sync_history_min_${channel.id}`, syncHistoryMin.toISOString());
    }

    await this.addEnabledChannel(channel.id);

    const initialState: InitialSyncState = {
      lastSyncTime: syncHistoryMin ?? undefined,
    };
    await this.set(`initial_state_${channel.id}`, initialState);

    // Queue per-channel initial backfill (label-scoped paginated thread list)
    // as a separate task so onChannelEnabled returns quickly.
    const initialCallback = await this.callback(
      this.initialSyncBatch,
      channel.id,
      1
    );
    await this.runTask(initialCallback);

    // Queue mailbox-wide webhook setup as a separate task to avoid blocking
    // the HTTP response. ensureMailboxWebhook is idempotent: if the watch
    // already exists from a previously-enabled channel, this is a no-op
    // beyond bumping the renewal cadence.
    const webhookCallback = await this.callback(this.ensureMailboxWebhook);
    await this.runTask(webhookCallback);
  }

  async onChannelDisabled(channel: Channel): Promise<void> {
    await this.removeEnabledChannel(channel.id);
    await this.clear(`initial_state_${channel.id}`);
    await this.clear(`sync_history_min_${channel.id}`);

    // If no enabled channels remain, tear the mailbox watch down. The next
    // onChannelEnabled will rebuild it.
    const enabled = await this.getEnabledChannels();
    if (enabled.size === 0) {
      await this.teardownMailboxWebhook();
    }
  }

  private async getApi(channelId: string): Promise<GmailApi> {
    const token = await this.tools.integrations.get(channelId);
    if (!token) {
      throw new Error("No Google authentication token available");
    }
    return new GmailApi(token.token);
  }

  async listLabels(channelId: string): Promise<MessageChannel[]> {
    const api = await this.getApi(channelId);
    const labels = await api.getLabels();

    const channels: MessageChannel[] = [];

    // Add standard labels as channels
    for (const label of labels) {
      // Filter out system labels that don't make sense as channels
      if (
        label.type === "system" &&
        !["INBOX", "SENT", "DRAFT", "IMPORTANT", "STARRED"].includes(label.id)
      ) {
        continue;
      }

      channels.push({
        id: label.id,
        name: label.name,
        description: `${label.messagesTotal || 0} messages, ${
          label.messagesUnread || 0
        } unread`,
        primary: label.id === "INBOX",
      });
    }

    // Add a special "search" channel option
    channels.push({
      id: "search:from:important@example.com",
      name: "Search (Custom Query)",
      description: "Use custom Gmail search queries as channels",
      primary: false,
    });

    return channels;
  }

  async startSync(
    options: {
      channelId: string;
    } & MessageSyncOptions
  ): Promise<void> {
    const { channelId, timeMin } = options;

    const initialState: InitialSyncState = {
      lastSyncTime: timeMin
        ? typeof timeMin === "string"
          ? new Date(timeMin)
          : timeMin
        : undefined,
    };

    await this.set(`initial_state_${channelId}`, initialState);
    await this.addEnabledChannel(channelId);

    const initialCallback = await this.callback(
      this.initialSyncBatch,
      channelId,
      1
    );
    await this.runTask(initialCallback);

    const webhookCallback = await this.callback(this.ensureMailboxWebhook);
    await this.runTask(webhookCallback);
  }

  async stopSync(channelId: string): Promise<void> {
    await this.removeEnabledChannel(channelId);
    await this.clear(`initial_state_${channelId}`);

    // Tear down the mailbox watch only if this was the last enabled channel.
    const enabled = await this.getEnabledChannels();
    if (enabled.size === 0) {
      await this.teardownMailboxWebhook();
    }
  }

  /**
   * Idempotently set up the mailbox-wide Gmail watch + Pub/Sub topic.
   * Called every time a channel is enabled; first call creates the webhook,
   * subsequent calls are no-ops.
   *
   * The watch is registered with no `labelIds`, so Gmail notifies us on every
   * mailbox change — including replies in existing threads that don't carry
   * the label of any enabled channel. The connector decides per-thread which
   * enabled channel(s) the change is relevant to.
   */
  async ensureMailboxWebhook(): Promise<void> {
    const existing = await this.get<MailboxWebhookState>("mailbox_webhook");
    if (existing) return;
    await this.setupMailboxWebhook();
  }

  private async setupMailboxWebhook(): Promise<void> {
    // createWebhook returns a Pub/Sub topic name when the provider is Google
    // with Gmail scopes. The webhook delivers no extra args — onGmailWebhook
    // operates on the single mailbox-wide watch.
    const topicName = await this.tools.network.createWebhook(
      {},
      this.onGmailWebhook
    );

    const api = await this.getApiAny();
    if (!api) {
      console.warn(
        "ensureMailboxWebhook: no enabled channel to source auth from"
      );
      return;
    }

    try {
      // No labelId → mailbox-wide notifications.
      const watchResult = await api.setupWatch(topicName);
      const expiration = new Date(parseInt(watchResult.expiration));

      await this.set<MailboxWebhookState>("mailbox_webhook", {
        topicName,
        historyId: watchResult.historyId,
        expiration,
        created: new Date().toISOString(),
      });

      // Seed the incremental cursor so the first webhook has somewhere to
      // start. Gmail's watch returns the current historyId; any change after
      // this point will appear in history.list from this seed.
      const existingIncremental =
        await this.get<{ historyId?: string }>("incremental_state");
      if (!existingIncremental?.historyId) {
        await this.set("incremental_state", {
          historyId: watchResult.historyId,
          lastSyncTime: new Date(),
        });
      }

      await this.scheduleMailboxRenewal(expiration);
    } catch (error) {
      console.error("Failed to setup Gmail mailbox webhook:", error);
    }
  }

  /**
   * Cancel renewal, stop the Gmail watch, delete the Pub/Sub topic, and
   * clear all mailbox-watch state. Called when the last channel is disabled
   * (and from preUpgrade for stale per-channel state).
   */
  private async teardownMailboxWebhook(): Promise<void> {
    const taskToken = await this.get<string>("mailbox_renewal_task");
    if (taskToken) {
      try {
        await this.cancelTask(taskToken);
      } catch {
        // Task may have already executed
      }
      await this.clear("mailbox_renewal_task");
    }

    const api = await this.getApiAny();
    if (api) {
      try {
        await api.stopWatch();
      } catch (error) {
        console.error("Failed to stop Gmail watch:", error);
      }
    }

    const webhook = await this.get<MailboxWebhookState>("mailbox_webhook");
    if (webhook?.topicName) {
      try {
        await this.tools.network.deleteWebhook(webhook.topicName);
      } catch (error) {
        console.error("Failed to delete Gmail webhook:", error);
      }
    }
    await this.clear("mailbox_webhook");
    await this.clear("incremental_state");
  }

  /**
   * Schedules a task to renew the Gmail watch before its 7-day expiry.
   * Renews 1 day before expiration.
   */
  private async scheduleMailboxRenewal(expiration: Date): Promise<void> {
    const existingTask = await this.get<string>("mailbox_renewal_task");
    if (existingTask) {
      try {
        await this.cancelTask(existingTask);
      } catch {
        // Task may have already executed
      }
      await this.clear("mailbox_renewal_task");
    }

    const renewalTime = new Date(expiration.getTime() - 24 * 60 * 60 * 1000);

    if (renewalTime <= new Date()) {
      // Already past renewal window, renew immediately
      await this.renewMailboxWatch();
      return;
    }

    const renewalCallback = await this.callback(this.renewMailboxWatch);
    const taskToken = await this.runTask(renewalCallback, {
      runAt: renewalTime,
    });
    if (taskToken) {
      await this.set("mailbox_renewal_task", taskToken);
    }
  }

  /**
   * Renews the Gmail mailbox watch before it expires. On failure, falls back
   * to a full mailbox-webhook re-setup.
   */
  async renewMailboxWatch(): Promise<void> {
    try {
      const api = await this.getApiAny();
      if (!api) return;

      const webhook = await this.get<MailboxWebhookState>("mailbox_webhook");
      if (!webhook?.topicName) {
        await this.setupMailboxWebhook();
        return;
      }

      const watchResult = await api.setupWatch(webhook.topicName);
      const expiration = new Date(parseInt(watchResult.expiration));

      await this.set<MailboxWebhookState>("mailbox_webhook", {
        ...webhook,
        historyId: watchResult.historyId,
        expiration,
      });

      await this.scheduleMailboxRenewal(expiration);
    } catch (error) {
      console.error("Failed to renew Gmail mailbox watch:", error);
      try {
        await this.setupMailboxWebhook();
      } catch (retryError) {
        console.error(
          "Failed to recreate Gmail mailbox webhook:",
          retryError
        );
      }
    }
  }

  /**
   * Per-channel initial backfill. Walks `users.threads.list?labelIds=<id>`
   * paginated and processes results. Used the FIRST time a channel is
   * enabled; ongoing changes flow through `incrementalSyncBatch` instead.
   */
  async initialSyncBatch(
    channelId: string,
    batchNumber: number
  ): Promise<void> {
    try {
      // Channel may have been disabled between scheduling and execution.
      if (!(await this.isChannelEnabled(channelId))) {
        await this.clear(`initial_state_${channelId}`);
        return;
      }

      const cursor = await this.get<InitialSyncState>(
        `initial_state_${channelId}`
      );
      if (!cursor) {
        // Already completed.
        return;
      }

      const token = await this.tools.integrations.get(channelId);
      if (!token) {
        console.warn(
          `Auth token missing for channel ${channelId} at initial batch ${batchNumber}, skipping`
        );
        return;
      }
      const api = new GmailApi(token.token);

      // Reuse the existing per-channel full-sync helper for label-scoped
      // pagination. We pass a shim SyncState matching its expectations.
      const syncState: SyncState = {
        channelId,
        pageToken: cursor.pageToken,
        lastSyncTime: cursor.lastSyncTime,
      };
      const result = await syncGmailChannel(api, syncState, 20);

      if (result.threads.length > 0) {
        // Initial backfill: every fetched thread is in this channel's label
        // (we asked Gmail for them by label), so route them all here.
        await this.processEmailThreads(result.threads, true, channelId);
      }

      if (result.hasMore) {
        await this.set<InitialSyncState>(`initial_state_${channelId}`, {
          pageToken: result.state.pageToken,
          lastSyncTime: result.state.lastSyncTime,
        });
        const next = await this.callback(
          this.initialSyncBatch,
          channelId,
          batchNumber + 1
        );
        await this.runTask(next);
      } else {
        // Backfill done. Drop the cursor and clear the "syncing…" UI.
        await this.clear(`initial_state_${channelId}`);
        await this.tools.integrations.channelSyncCompleted(channelId);
      }
    } catch (error) {
      console.error(
        `Error in initial sync batch ${batchNumber} for channel ${channelId}:`,
        error
      );
      throw error;
    }
  }

  /**
   * Mailbox-wide incremental sync. Triggered from a Pub/Sub webhook. Calls
   * Gmail's history.list with NO label filter so we see every change, then
   * routes each affected thread to whichever enabled channel(s) it actually
   * matches (based on its messages' labels). On 404 (history-window
   * expired), reseeds the cursor from the watch's current historyId — we
   * don't re-walk every label here, since label-scoped re-walks happen
   * via a fresh onChannelEnabled if needed.
   */
  async incrementalSyncBatch(): Promise<void> {
    try {
      const enabled = await this.getEnabledChannels();
      if (enabled.size === 0) return;

      const state = await this.get<{
        historyId?: string;
        lastSyncTime?: Date;
      }>("incremental_state");
      if (!state?.historyId) {
        // Nothing to do — webhook will re-seed on next watch setup.
        return;
      }

      const api = await this.getApiAny();
      if (!api) {
        console.warn(
          "incrementalSyncBatch: no enabled channel to source auth from"
        );
        return;
      }

      const result = await syncGmailMailboxIncremental(api, state.historyId);
      if (result.expired) {
        // Recover by reseeding from the watch's most recent historyId.
        const webhook =
          await this.get<MailboxWebhookState>("mailbox_webhook");
        if (webhook?.historyId) {
          await this.set("incremental_state", {
            historyId: webhook.historyId,
            lastSyncTime: new Date(),
          });
        } else {
          await this.clear("incremental_state");
        }
        console.warn(
          "Gmail mailbox history expired; reseeded incremental cursor"
        );
        return;
      }

      if (result.threads.length > 0) {
        await this.processEmailThreads(result.threads, false);
      }

      await this.set("incremental_state", {
        historyId: result.historyId,
        lastSyncTime: new Date(),
      });
    } catch (error) {
      console.error("Error in Gmail incremental sync batch:", error);
      throw error;
    }
  }

  /**
   * Backwards-compatible shim for callbacks deployed under the old
   * per-channel sync architecture. New deploys should never produce this
   * callback; this exists so already-queued callbacks finish gracefully.
   */
  async syncBatch(
    _batchNumber: number,
    mode: "full" | "incremental",
    channelId: string,
    _initialSync?: boolean
  ): Promise<void> {
    if (mode === "full") {
      // Forward to the new per-channel initial backfill. Seed the cursor
      // so initialSyncBatch has something to read.
      const existing = await this.get<InitialSyncState>(
        `initial_state_${channelId}`
      );
      if (!existing) {
        await this.set<InitialSyncState>(`initial_state_${channelId}`, {});
      }
      await this.initialSyncBatch(channelId, 1);
      return;
    }
    // Old "incremental" callback — forward to mailbox-wide sync.
    await this.incrementalSyncBatch();
  }

  /**
   * Backwards-compatible shim for callbacks deployed under the old
   * per-channel webhook architecture. Forwards to mailbox-wide setup.
   */
  async setupChannelWebhook(_channelId: string): Promise<void> {
    await this.ensureMailboxWebhook();
  }

  /**
   * Backwards-compatible shim for old per-channel watch-renewal tasks.
   */
  async renewWatch(_channelId: string): Promise<void> {
    await this.renewMailboxWatch();
  }

  private async processEmailThreads(
    threads: GmailThread[],
    initialSync: boolean,
    forceChannelId?: string
  ): Promise<void> {
    // When forceChannelId is set we already know which channel owns these
    // threads (per-channel initial backfill). For mailbox-wide incremental
    // sync we pick a channel per thread by inspecting its message labels.
    const enabledChannels = forceChannelId
      ? new Set([forceChannelId])
      : await this.getEnabledChannels();
    if (enabledChannels.size === 0) return;

    // Pre-build all plot threads, then enrich every contact email across the
    // batch in one People API pass. Gmail headers don't carry avatars, so
    // without this every email-only contact lands with `avatar = undefined`
    // and shows initials forever.
    const transformed: {
      thread: GmailThread;
      plot: ReturnType<typeof transformGmailThread>;
      channelId: string;
    }[] = [];
    const allEmails = new Set<string>();
    for (const thread of threads) {
      const plot = transformGmailThread(thread);
      if (!plot.notes || plot.notes.length === 0) continue;

      const chosen =
        forceChannelId ?? pickChannelForThread(thread, enabledChannels);
      if (!chosen) continue; // Thread doesn't match any enabled channel.

      transformed.push({ thread, plot, channelId: chosen });
      for (const c of plot.accessContacts ?? []) {
        if (c && typeof c === "object" && "email" in c && c.email)
          allEmails.add(c.email);
      }
      for (const note of plot.notes) {
        const author = (note as { author?: { email?: string } }).author;
        if (author?.email) allEmails.add(author.email);
        const noteContacts = (note as { accessContacts?: Array<{ email?: string }> }).accessContacts;
        for (const c of noteContacts ?? []) {
          if (c?.email) allEmails.add(c.email);
        }
      }
    }

    if (allEmails.size > 0) {
      // Auth scope is per-account, not per-channel; any enabled channel ID
      // sources the same token.
      const authChannelId =
        forceChannelId ?? transformed[0]?.channelId ?? null;
      if (authChannelId) {
        try {
          const token = await this.tools.integrations.get(authChannelId);
          if (token) {
            await enrichLinkContactsFromGoogle(
              transformed.map((t) => t.plot),
              token.token,
              token.scopes,
            );
          }
        } catch (err) {
          // Enrichment is best-effort — Gravatar fallback in the client still
          // covers anyone the People API doesn't return.
          console.warn(
            "Failed to enrich Gmail contacts (non-blocking):",
            err
          );
        }
      }
    }

    for (const { thread, plot: plotThread, channelId } of transformed) {
      try {
        if (!plotThread.notes || plotThread.notes.length === 0) continue;

        // Filter out notes for messages we sent (dedup)
        const filtered = [];
        for (const note of plotThread.notes) {
          const noteKey = "key" in note ? (note as { key: string }).key : null;
          if (noteKey) {
            const wasSent = await this.get<boolean>(`sent:${noteKey}`);
            if (wasSent) {
              await this.clear(`sent:${noteKey}`);
              continue;
            }
          }
          filtered.push(note);
        }
        plotThread.notes = filtered;

        if (plotThread.notes.length === 0) continue;

        if (initialSync) {
          plotThread.unread = false;
          plotThread.archived = false;
        }

        // Inject channel ID for priority routing and sync metadata
        plotThread.channelId = channelId;
        plotThread.meta = {
          ...plotThread.meta,
          syncProvider: "google",
          syncableId: channelId,
        };

        // Star ↔ todo sync: detect star changes and update Plot todo status
        const isStarred = GmailApi.isStarred(thread);
        const isArchived = !thread.messages?.some((m) =>
          m.labelIds?.includes("INBOX")
        );

        // Set status based on labels
        if (isStarred) {
          plotThread.status = "starred";
        } else if (isArchived) {
          plotThread.status = "archived";
        } else {
          plotThread.status = "inbox";
        }

        // Save link directly via integrations
        const savedThreadId = await this.tools.integrations.saveLink(plotThread);
        if (!savedThreadId) continue; // Link was filtered (e.g., older than sync history) — skip star sync

        const wasStarred = await this.get<boolean>(`starred:${thread.id}`);

        // Echo suppression relies entirely on the `starred` state: when
        // Plot→Gmail writes STARRED, onThreadToDo/onLinkUpdated update this
        // state *before* the API call. The resulting Gmail webhook sees
        // isStarred === wasStarred and this branch doesn't run.
        if (isStarred !== !!wasStarred) {
          const actorId = await this.get<ActorId>("auth_actor_id");
          // Use the canonical Gmail thread URL as the source identifier
          const sourceUrl = `https://mail.google.com/mail/u/0/#inbox/${thread.id}`;
          if (actorId) {
            await this.tools.integrations.setThreadToDo(
              sourceUrl,
              actorId,
              isStarred
            );
            // Prevent the onThreadToDo callback from echoing back
            await this.set(`skip_todo_writeback:${thread.id}`, true);
          }
          await this.set(`starred:${thread.id}`, isStarred);
        }
      } catch (error) {
        console.error(`Failed to process Gmail thread ${thread.id}:`, error);
        // Continue processing other threads
      }
    }
  }

  async onNoteCreated(
    note: Note,
    thread: Thread
  ): Promise<NoteWriteBackResult | void> {
    const meta = thread.meta ?? {};
    const channelId = (meta.channelId ?? meta.syncableId) as string;
    if (!channelId) {
      console.error("No channelId in meta for Gmail reply");
      return;
    }

    const threadId = meta.threadId as string;
    if (!threadId) {
      console.error("No threadId in meta for Gmail reply");
      return;
    }

    const api = await this.getApi(channelId);

    // Fetch the full Gmail thread to get message headers
    const gmailThread = await api.getThread(threadId);
    if (!gmailThread.messages || gmailThread.messages.length === 0) {
      console.error("Gmail thread has no messages");
      return;
    }

    // Determine target message: specific replied-to note or last message in thread
    let targetMessage = gmailThread.messages[gmailThread.messages.length - 1];
    if (meta.reNoteKey) {
      const found = gmailThread.messages.find(
        (m) => m.id === meta.reNoteKey
      );
      if (found) {
        targetMessage = found;
      }
    }

    // Extract headers from target message
    const messageId = getHeader(targetMessage, "Message-ID");
    const references = getHeader(targetMessage, "References");
    const subject = getHeader(targetMessage, "Subject") ?? "Email";
    const fromHeader = getHeader(targetMessage, "From");
    const toHeader = getHeader(targetMessage, "To");
    const ccHeader = getHeader(targetMessage, "Cc");

    if (!messageId) {
      console.error("Target message has no Message-ID header");
      return;
    }

    // Get sender's email to exclude from reply-all recipients
    const profile = await api.getProfile();
    const senderEmail = profile.emailAddress.toLowerCase();

    // Build reply-all recipients: all From + To + Cc minus sender, deduplicated
    const allRecipients = new Set<string>();
    for (const email of parseEmailAddresses(fromHeader)) {
      allRecipients.add(email.toLowerCase());
    }
    for (const email of parseEmailAddresses(toHeader)) {
      allRecipients.add(email.toLowerCase());
    }

    const ccRecipients = new Set<string>();
    for (const email of parseEmailAddresses(ccHeader)) {
      ccRecipients.add(email.toLowerCase());
    }

    // Remove sender from all sets
    allRecipients.delete(senderEmail);
    ccRecipients.delete(senderEmail);

    // To = all direct recipients (From + To minus sender), Cc = remaining Cc
    const to = Array.from(allRecipients).filter(
      (email) => !ccRecipients.has(email)
    );
    const cc = Array.from(ccRecipients);

    if (to.length === 0 && cc.length === 0) {
      console.error("No recipients for Gmail reply");
      return;
    }

    // Build and send the reply
    const raw = buildReplyMessage({
      to,
      cc,
      from: senderEmail,
      subject,
      body: note.content ?? "",
      messageId,
      references: references ?? "",
    });

    const result = await api.sendMessage(raw, threadId);

    // Store sent message ID for dedup when synced back
    await this.set(`sent:${result.id}`, true);

    // Return the Gmail message id as the note key so the runtime links this
    // Plot note to the sent message. We intentionally do NOT provide
    // `externalContent`: Gmail does not return the normalized message body
    // from `send`, and fetching + parsing the multipart payload just to
    // compute a baseline is expensive. The first incremental sync-in of the
    // sent message will establish the baseline naturally (runtime records
    // the stored content as the baseline on first external ingest).
    return { key: result.id };
  }

  async onThreadRead(
    thread: Thread,
    _actor: Actor,
    unread: boolean
  ): Promise<void> {
    const meta = thread.meta ?? {};
    const channelId = (meta.channelId ?? meta.syncableId) as string;
    if (!channelId) return;

    const threadId = meta.threadId as string;
    if (!threadId) return;

    const api = await this.getApi(channelId);

    if (unread) {
      await api.modifyThread(threadId, ["UNREAD"]);
    } else {
      await api.modifyThread(threadId, undefined, ["UNREAD"]);
    }
  }

  async onThreadToDo(
    thread: Thread,
    _actor: Actor,
    todo: boolean,
    _options: { date?: Date }
  ): Promise<void> {
    const meta = thread.meta ?? {};
    const threadId = meta.threadId as string;
    const channelId = (meta.channelId ?? meta.syncableId) as string;
    if (!threadId || !channelId) return;

    // Loop prevention: skip if this change originated from Gmail star sync
    if (await this.get(`skip_todo_writeback:${threadId}`)) {
      await this.clear(`skip_todo_writeback:${threadId}`);
      return;
    }

    // Update local state BEFORE calling Gmail, so the webhook fired by our
    // own write sees isStarred === wasStarred and doesn't re-propagate.
    await this.set(`starred:${threadId}`, todo);

    const api = await this.getApi(channelId);
    if (todo) {
      // Add STARRED, and re-add INBOX so an archived email returns to the
      // inbox when the user adds it to their agenda in Plot.
      await api.modifyThread(threadId, ["STARRED", "INBOX"]);
    } else {
      await api.modifyThread(threadId, undefined, ["STARRED"]);
    }
  }

  async onLinkUpdated(link: Link): Promise<void> {
    const threadId = link.meta?.threadId as string | undefined;
    const channelId = (link.meta?.channelId ?? link.meta?.syncableId) as
      | string
      | undefined;
    if (!threadId || !channelId) return;

    // Loop prevention: skip if this change originated from Gmail star sync
    if (await this.get(`skip_todo_writeback:${threadId}`)) {
      await this.clear(`skip_todo_writeback:${threadId}`);
      return;
    }

    const status = link.status;

    // Update local state BEFORE calling Gmail, so the webhook fired by our
    // own write sees isStarred === wasStarred and doesn't re-propagate.
    await this.set(`starred:${threadId}`, status === "starred");

    const api = await this.getApi(channelId);

    if (status === "starred") {
      await api.modifyThread(threadId, ["STARRED"]);
    } else if (status === "archived") {
      // Archive = remove from INBOX. Also unstar.
      await api.modifyThread(threadId, undefined, ["INBOX", "STARRED"]);
    } else if (status === "inbox") {
      // Back to inbox, unstar.
      await api.modifyThread(threadId, ["INBOX"], ["STARRED"]);
    }
  }

  /**
   * Pub/Sub webhook handler. Single mailbox-wide watch → single handler.
   * Decodes Gmail's history-id notification and queues a mailbox-incremental
   * sync as a separate task so this handler returns quickly to Pub/Sub.
   *
   * The optional `_channelId` argument exists for backwards compatibility
   * with already-deployed per-channel webhook callbacks (which were
   * registered with `extraArgs: [channelId]`). The new mailbox-wide watch
   * registers without extraArgs, so newer deploys never pass a channelId.
   */
  async onGmailWebhook(
    request: WebhookRequest,
    _channelId?: string
  ): Promise<void> {
    const body = request.body as { message?: { data: string } };
    const message = body?.message;
    if (!message) {
      console.warn("No message in Gmail webhook body");
      return;
    }

    let data: { historyId?: string; emailAddress?: string };
    try {
      const decoded = atob(message.data);
      data = JSON.parse(decoded);
    } catch (error) {
      console.error("Failed to decode Gmail webhook message:", error);
      return;
    }

    if (!data.historyId) return;

    // Renew the watch if its expiration has passed.
    const webhook = await this.get<MailboxWebhookState>("mailbox_webhook");
    if (webhook?.expiration && new Date(webhook.expiration) < new Date()) {
      await this.renewMailboxWatch();
    }

    // Make sure incremental_state exists (carries our last-acknowledged
    // historyId). If we somehow lost it, seed from the webhook's historyId
    // — we'll miss anything that happened between teardown and now, but
    // that's strictly bounded.
    const existing = await this.get<{ historyId?: string }>(
      "incremental_state"
    );
    if (!existing?.historyId) {
      await this.set("incremental_state", {
        historyId: data.historyId,
        lastSyncTime: new Date(),
      });
    }

    const callback = await this.callback(this.incrementalSyncBatch);
    await this.runTask(callback);
  }

  // Helpers ------------------------------------------------------------------

  /** Returns the set of channelIds the user currently has enabled. */
  private async getEnabledChannels(): Promise<Set<string>> {
    const list = (await this.get<string[]>("enabled_channels")) ?? [];
    return new Set(list);
  }

  /** Add a channelId to the enabled set (idempotent, preserves order). */
  private async addEnabledChannel(channelId: string): Promise<void> {
    const list = (await this.get<string[]>("enabled_channels")) ?? [];
    if (list.includes(channelId)) return;
    list.push(channelId);
    await this.set("enabled_channels", list);
  }

  /** Remove a channelId from the enabled set. */
  private async removeEnabledChannel(channelId: string): Promise<void> {
    const list = (await this.get<string[]>("enabled_channels")) ?? [];
    const filtered = list.filter((c) => c !== channelId);
    if (filtered.length === list.length) return;
    await this.set("enabled_channels", filtered);
  }

  /** Whether a channel is currently enabled. */
  private async isChannelEnabled(channelId: string): Promise<boolean> {
    const list = (await this.get<string[]>("enabled_channels")) ?? [];
    return list.includes(channelId);
  }

  /**
   * Returns a Gmail API client authed with any enabled channel's token.
   * Auth is per-Google-account (not per-label), so any enabled channelId
   * resolves to the same OAuth credential.
   */
  private async getApiAny(): Promise<GmailApi | null> {
    const enabled = await this.getEnabledChannels();
    for (const channelId of enabled) {
      const token = await this.tools.integrations.get(channelId);
      if (token?.token) return new GmailApi(token.token);
    }
    return null;
  }
}

/**
 * Pick which enabled channel a thread should be filed under, based on the
 * labels carried by its messages. Selection precedence (most specific first):
 *
 *   1. Custom (user-defined) labels — alphabetically.
 *   2. STARRED → IMPORTANT → INBOX → SENT → DRAFT (system labels).
 *
 * Returns null if no enabled channel matches the thread (the thread came in
 * via mailbox-wide history but doesn't belong to any channel the user wants).
 *
 * Custom labels in Gmail use IDs like `Label_14`. We treat anything not in
 * the system-label list above as "custom", which matches getChannels()'s
 * own filter.
 */
function pickChannelForThread(
  thread: GmailThread,
  enabledChannels: Set<string>
): string | null {
  // Collect every label that appears on any message in the thread.
  const threadLabels = new Set<string>();
  for (const m of thread.messages ?? []) {
    for (const l of m.labelIds ?? []) threadLabels.add(l);
  }

  // Custom labels first, alphabetical for stability.
  const customMatches: string[] = [];
  for (const enabled of enabledChannels) {
    if (SYSTEM_LABEL_ORDER.includes(enabled)) continue;
    if (threadLabels.has(enabled)) customMatches.push(enabled);
  }
  if (customMatches.length > 0) {
    customMatches.sort();
    return customMatches[0];
  }

  // System labels in fixed precedence order.
  for (const label of SYSTEM_LABEL_ORDER) {
    if (enabledChannels.has(label) && threadLabels.has(label)) return label;
  }

  return null;
}

export default Gmail;
