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
  transformGmailThread,
} from "./gmail-api";

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
    // Check if we've already synced with a wider or equal range
    const syncHistoryMin = context?.syncHistoryMin;
    if (syncHistoryMin) {
      const storedMin = await this.get<string>(`sync_history_min_${channel.id}`);
      if (storedMin && new Date(storedMin) <= syncHistoryMin) {
        return; // Already synced with wider range
      }
      await this.set(`sync_history_min_${channel.id}`, syncHistoryMin.toISOString());
    }

    await this.set(`sync_enabled_${channel.id}`, true);

    const initialState: SyncState = {
      channelId: channel.id,
      lastSyncTime: syncHistoryMin ?? undefined,
    };
    await this.set(`sync_state_${channel.id}`, initialState);

    // Queue sync batch as a separate task so onChannelEnabled returns quickly
    const syncCallback = await this.callback(
      this.syncBatch,
      1,
      "full",
      channel.id,
      true
    );
    await this.runTask(syncCallback);

    // Queue webhook setup as a separate task to avoid blocking the HTTP response.
    // setupChannelWebhook makes multiple API calls (createWebhook, Gmail watch API,
    // scheduleWatchRenewal) that would block the response if run inline.
    const webhookCallback = await this.callback(
      this.setupChannelWebhook,
      channel.id
    );
    await this.runTask(webhookCallback);
  }

  async onChannelDisabled(channel: Channel): Promise<void> {
    await this.stopSync(channel.id);
    await this.clear(`sync_enabled_${channel.id}`);
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

    const initialState: SyncState = {
      channelId,
      lastSyncTime: timeMin
        ? typeof timeMin === "string"
          ? new Date(timeMin)
          : timeMin
        : undefined,
    };

    await this.set(`sync_state_${channelId}`, initialState);

    // Queue sync and webhook setup as separate tasks
    const syncCallback = await this.callback(
      this.syncBatch,
      1,
      "full",
      channelId,
      true
    );
    await this.runTask(syncCallback);

    const webhookCallback = await this.callback(
      this.setupChannelWebhook,
      channelId
    );
    await this.runTask(webhookCallback);
  }

  async stopSync(channelId: string): Promise<void> {
    // Cancel scheduled watch renewal
    const taskToken = await this.get<string>(
      `watch_renewal_task_${channelId}`
    );
    if (taskToken) {
      try {
        await this.cancelTask(taskToken);
      } catch {
        // Task may have already executed
      }
      await this.clear(`watch_renewal_task_${channelId}`);
    }

    // Stop watching for push notifications
    const api = await this.getApi(channelId);
    try {
      await api.stopWatch();
    } catch (error) {
      console.error("Failed to stop Gmail watch:", error);
    }

    // Clear webhook
    await this.clear(`channel_webhook_${channelId}`);

    // Clear sync state
    await this.clear(`sync_state_${channelId}`);
  }

  async setupChannelWebhook(channelId: string): Promise<void> {
    // Create Gmail webhook (returns Pub/Sub topic name, not a URL)
    // When provider is Google with Gmail scopes, createWebhook returns a Pub/Sub topic name
    const topicName = await this.tools.network.createWebhook(
      {},
      this.onGmailWebhook,
      channelId
    );

    const api = await this.getApi(channelId);

    try {
      // Setup Gmail watch with the Pub/Sub topic name
      // topicName format: projects/{project_id}/topics/{topic_name}
      const watchResult = await api.setupWatch(channelId, topicName);

      const expiration = new Date(parseInt(watchResult.expiration));

      // Store webhook data including expiration
      await this.set(`channel_webhook_${channelId}`, {
        topicName,
        channelId,
        historyId: watchResult.historyId,
        expiration,
        created: new Date().toISOString(),
      });

      // Schedule watch renewal before the 7-day expiry
      await this.scheduleWatchRenewal(channelId, expiration);
    } catch (error) {
      console.error("Failed to setup Gmail webhook:", error);
    }
  }

  /**
   * Schedules a task to renew the Gmail watch before its expiry.
   * Renews 1 day before expiration.
   */
  private async scheduleWatchRenewal(
    channelId: string,
    expiration: Date
  ): Promise<void> {
    // Cancel any existing renewal task
    const existingTask = await this.get<string>(
      `watch_renewal_task_${channelId}`
    );
    if (existingTask) {
      try {
        await this.cancelTask(existingTask);
      } catch {
        // Task may have already executed
      }
      await this.clear(`watch_renewal_task_${channelId}`);
    }

    // Renew 1 day before expiry
    const renewalTime = new Date(expiration.getTime() - 24 * 60 * 60 * 1000);

    if (renewalTime <= new Date()) {
      // Already past renewal window, renew immediately
      await this.renewWatch(channelId);
      return;
    }

    const renewalCallback = await this.callback(
      this.renewWatch,
      channelId
    );
    const taskToken = await this.runTask(renewalCallback, {
      runAt: renewalTime,
    });
    if (taskToken) {
      await this.set(`watch_renewal_task_${channelId}`, taskToken);
    }
  }

  /**
   * Renews the Gmail watch before it expires.
   * If renewal fails, falls back to full webhook setup.
   */
  async renewWatch(channelId: string): Promise<void> {
    try {
      const api = await this.getApi(channelId);
      const webhookData = await this.get<{
        topicName: string;
        channelId: string;
      }>(`channel_webhook_${channelId}`);

      if (!webhookData?.topicName) {
        // No existing webhook data, do full setup
        await this.setupChannelWebhook(channelId);
        return;
      }

      // Re-call watch with the same topic
      const watchResult = await api.setupWatch(channelId, webhookData.topicName);
      const expiration = new Date(parseInt(watchResult.expiration));

      await this.set(`channel_webhook_${channelId}`, {
        ...webhookData,
        historyId: watchResult.historyId,
        expiration,
      });

      // Schedule next renewal
      await this.scheduleWatchRenewal(channelId, expiration);
    } catch (error) {
      console.error(`Failed to renew Gmail watch for ${channelId}:`, error);
      // Try full setup as fallback
      try {
        await this.setupChannelWebhook(channelId);
      } catch (retryError) {
        console.error("Failed to recreate Gmail webhook:", retryError);
      }
    }
  }

  async syncBatch(
    batchNumber: number,
    mode: "full" | "incremental",
    channelId: string,
    initialSync?: boolean
  ): Promise<void> {
    const isInitial = initialSync ?? mode === "full";
    try {
      const state = await this.get<SyncState>(`sync_state_${channelId}`);
      if (!state) {
        // State was cleared by a concurrent operation (channel disabled,
        // incremental sync race, etc.) — return gracefully instead of
        // throwing to prevent infinite queue retries.
        console.warn(
          `Sync state missing for channel ${channelId} at batch ${batchNumber}, skipping`
        );
        return;
      }

      const token = await this.tools.integrations.get(channelId);
      if (!token) {
        // Auth token was cleared (channel disabled, OAuth revoked,
        // integration deleted) — abort instead of throwing to prevent
        // infinite queue retries.
        console.warn(
          `Auth token missing for channel ${channelId} at batch ${batchNumber}, skipping`
        );
        return;
      }
      const api = new GmailApi(token.token);

      // Use smaller batch size for Gmail (20 threads) to avoid timeouts
      const result = await syncGmailChannel(api, state, 20);

      if (result.threads.length > 0) {
        await this.processEmailThreads(result.threads, channelId, isInitial);
      }

      await this.set(`sync_state_${channelId}`, result.state);

      if (result.hasMore) {
        const syncCallback = await this.callback(
          this.syncBatch,
          batchNumber + 1,
          mode,
          channelId,
          isInitial
        );
        await this.runTask(syncCallback);
      } else {
        if (mode === "full") {
          await this.clear(`sync_state_${channelId}`);
        }
      }
    } catch (error) {
      console.error(
        `Error in sync batch ${batchNumber} for channel ${channelId}:`,
        error
      );

      throw error;
    }
  }

  private async processEmailThreads(
    threads: GmailThread[],
    channelId: string,
    initialSync: boolean
  ): Promise<void> {
    // Pre-build all plot threads, then enrich every contact email across the
    // batch in one People API pass. Gmail headers don't carry avatars, so
    // without this every email-only contact lands with `avatar = undefined`
    // and shows initials forever.
    const transformed: { thread: GmailThread; plot: ReturnType<typeof transformGmailThread> }[] = [];
    const allEmails = new Set<string>();
    for (const thread of threads) {
      const plot = transformGmailThread(thread);
      if (!plot.notes || plot.notes.length === 0) continue;
      transformed.push({ thread, plot });
      for (const c of plot.accessContacts ?? []) {
        if (c && typeof c === "object" && "email" in c && c.email) allEmails.add(c.email);
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
      try {
        const token = await this.tools.integrations.get(channelId);
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
        console.warn("Failed to enrich Gmail contacts (non-blocking):", err);
      }
    }

    for (const { thread, plot: plotThread } of transformed) {
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

  async onGmailWebhook(
    request: WebhookRequest,
    channelId: string
  ): Promise<void> {
    // Gmail sends push notifications via Cloud Pub/Sub
    // The message body is base64-encoded
    const body = request.body as { message?: { data: string } };
    const message = body?.message;
    if (!message) {
      console.warn("No message in webhook body");
      return;
    }

    // Decode the Pub/Sub message
    let data: any;
    try {
      const decoded = atob(message.data);
      data = JSON.parse(decoded);
    } catch (error) {
      console.error("Failed to decode Gmail webhook message:", error);
      return;
    }

    // Gmail notifications contain historyId for incremental sync
    if (data.historyId) {
      await this.startIncrementalSync(channelId, data.historyId);
    }
  }

  private async startIncrementalSync(
    channelId: string,
    historyId: string
  ): Promise<void> {
    const webhookData = await this.get<any>(`channel_webhook_${channelId}`);
    if (!webhookData) {
      console.error("No channel webhook data found");
      return;
    }

    // Check if watch has expired and renew if needed
    const expiration = new Date(webhookData.expiration);
    if (expiration < new Date()) {
      await this.setupChannelWebhook(channelId);
    }

    // Don't interrupt an in-progress full sync (has pageToken for pagination).
    // The full sync will pick up any new changes when it completes.
    //
    // If the full sync is stale (hasn't advanced in 10 minutes), treat it as
    // stuck and overwrite with incremental state. Otherwise a crashed or
    // abandoned batch blocks every subsequent webhook indefinitely.
    const existingState = await this.get<SyncState>(`sync_state_${channelId}`);
    if (existingState?.pageToken) {
      const lastAdvance = existingState.lastSyncTime
        ? new Date(existingState.lastSyncTime).getTime()
        : 0;
      const stale = Date.now() - lastAdvance > 10 * 60 * 1000;
      if (!stale) return;
      console.warn(
        `Gmail full sync appears stuck on channel ${channelId} (lastSyncTime=${existingState.lastSyncTime}) — switching to incremental`
      );
    }

    // Use the stored historyId from the last sync if available, falling back
    // to the webhook's historyId. The stored ID is our last known position —
    // querying from there catches all changes. The webhook's historyId may
    // point past the actual change, causing getHistory() to miss it.
    const startHistoryId = existingState?.historyId ?? historyId;

    const incrementalState: SyncState = {
      channelId,
      historyId: startHistoryId,
      lastSyncTime: new Date(),
    };

    await this.set(`sync_state_${channelId}`, incrementalState);
    const syncCallback = await this.callback(
      this.syncBatch,
      1,
      "incremental",
      channelId,
      false
    );
    await this.runTask(syncCallback);
  }
}

export default Gmail;
