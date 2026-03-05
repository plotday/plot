import { Source, type ToolBuilder } from "@plotday/twister";
import type { Actor, ActorId, Note, Thread } from "@plotday/twister/plot";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  type Channel,
  Integrations,
} from "@plotday/twister/tools/integrations";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";

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
 * **Required OAuth Scopes:**
 * - `https://www.googleapis.com/auth/gmail.readonly` - Read emails
 * - `https://www.googleapis.com/auth/gmail.modify` - Modify labels
 */
export class Gmail extends Source<Gmail> {
  static readonly PROVIDER = AuthProvider.Google;
  static readonly SCOPES = [
    "https://www.googleapis.com/auth/gmail.readonly",
    "https://www.googleapis.com/auth/gmail.modify",
    "https://www.googleapis.com/auth/gmail.send",
  ];

  readonly provider = AuthProvider.Google;
  readonly scopes = Gmail.SCOPES;
  readonly linkTypes = [
    {
      type: "email",
      label: "Email",
      logo: "https://api.iconify.design/logos/google-gmail.svg",
      logoMono: "https://api.iconify.design/simple-icons/gmail.svg",
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

  async onChannelEnabled(channel: Channel): Promise<void> {
    await this.set(`sync_enabled_${channel.id}`, true);

    // Auto-start sync: setup webhook and queue first batch
    await this.setupChannelWebhook(channel.id);

    const initialState: SyncState = {
      channelId: channel.id,
    };

    await this.set(`sync_state_${channel.id}`, initialState);

    const syncCallback = await this.callback(
      this.syncBatch,
      1,
      "full",
      channel.id,
      true
    );
    await this.run(syncCallback);
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

    // Setup webhook for this channel (Gmail Push Notifications)
    await this.setupChannelWebhook(channelId);

    const initialState: SyncState = {
      channelId,
      lastSyncTime: timeMin
        ? typeof timeMin === "string"
          ? new Date(timeMin)
          : timeMin
        : undefined,
    };

    await this.set(`sync_state_${channelId}`, initialState);

    // Start sync batch using run tool for long-running operation
    const syncCallback = await this.callback(
      this.syncBatch,
      1,
      "full",
      channelId,
      true
    );
    await this.run(syncCallback);
  }

  async stopSync(channelId: string): Promise<void> {
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

  private async setupChannelWebhook(channelId: string): Promise<void> {
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

      // Store webhook data including expiration
      await this.set(`channel_webhook_${channelId}`, {
        topicName,
        channelId,
        historyId: watchResult.historyId,
        expiration: new Date(parseInt(watchResult.expiration)),
        created: new Date().toISOString(),
      });
    } catch (error) {
      console.error("Failed to setup Gmail webhook:", error);
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
        throw new Error("No sync state found");
      }

      const api = await this.getApi(channelId);

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
        await this.run(syncCallback);
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
    for (const thread of threads) {
      try {
        // Transform Gmail thread to NewLinkWithNotes
        const plotThread = transformGmailThread(thread);

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

        // Save link directly via integrations
        await this.tools.integrations.saveLink(plotThread);

        // Star ↔ todo sync: detect star changes and update Plot todo status
        const isStarred = GmailApi.isStarred(thread);
        const wasStarred = await this.get<boolean>(`starred:${thread.id}`);

        if (isStarred !== !!wasStarred) {
          // Skip if this change originated from Plot todo writeback
          if (await this.get(`skip_star_sync:${thread.id}`)) {
            await this.clear(`skip_star_sync:${thread.id}`);
          } else {
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
          }
          await this.set(`starred:${thread.id}`, isStarred);
        }
      } catch (error) {
        console.error(`Failed to process Gmail thread ${thread.id}:`, error);
        // Continue processing other threads
      }
    }
  }

  async onNoteCreated(note: Note, thread: Thread): Promise<void> {
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

    const api = await this.getApi(channelId);
    if (todo) {
      await api.modifyThread(threadId, ["STARRED"]);
    } else {
      await api.modifyThread(threadId, undefined, ["STARRED"]);
    }

    // Prevent the Gmail webhook from echoing this change back
    await this.set(`skip_star_sync:${threadId}`, true);
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

    // For incremental sync, use the historyId from the notification
    const incrementalState: SyncState = {
      channelId,
      historyId,
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
    await this.run(syncCallback);
  }
}

export default Gmail;
