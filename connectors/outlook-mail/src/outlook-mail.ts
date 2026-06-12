import {
  Connector,
  type CreateLinkDraft,
  type NoteWriteBackResult,
  type ToolBuilder,
} from "@plotday/twister";
import { ActionType } from "@plotday/twister/plot";
import type {
  Actor,
  ActorId,
  NewLinkWithNotes,
  Note,
  Thread,
} from "@plotday/twister/plot";
import {
  AuthProvider,
  type AuthToken,
  type Authorization,
  type Channel,
  Integrations,
  type SyncContext,
} from "@plotday/twister/tools/integrations";
import { Network, type WebhookRequest } from "@plotday/twister/tools/network";
import { Files } from "@plotday/twister/tools/files";

import { enrichLinkContactsFromOutlook, OUTLOOK_PEOPLE_SCOPES } from "./enrich";
import {
  EXCLUDED_WELL_KNOWN,
  GraphMailApi,
  GraphMailApiError,
  conversationSource,
  isConversationFlagged,
  isConversationUnread,
  recipientEmails,
  sortConversation,
  transformOutlookConversation,
  type GraphAttachmentMeta,
  type GraphHeader,
  type GraphMessage,
  type WellKnownFolders,
} from "./graph-mail-api";
import { outlookFacets } from "./outlook-facets";

/**
 * How often `selfHealCheck` runs while at least one channel is enabled.
 * Mirrors the Gmail connector's cadence: fast enough that a broken
 * subscription or missed notification is recovered within an hour, slow
 * enough to keep Graph API load negligible.
 */
const SELF_HEAL_INTERVAL_MS = 60 * 60 * 1000;

/**
 * If the subscription is within this window of expiry, `selfHealCheck`
 * re-establishes it preemptively rather than relying on
 * `mailbox_renewal_task` (which can fail to fire if the Durable Object
 * alarm is dropped on deploy/eviction). 36h gives the renewal task its
 * scheduled run plus a safety margin.
 */
const SUB_PREEMPTIVE_RENEW_MS = 36 * 60 * 60 * 1000;

/** Renew the Graph subscription this far before expiry. */
const RENEWAL_LEAD_MS = 24 * 60 * 60 * 1000;

/**
 * Graph caps Outlook-resource subscriptions at a few days; 3 days is the
 * value outlook-calendar has run in production, safely under every
 * documented cap.
 */
const SUBSCRIPTION_DURATION_DAYS = 3;

/** Max times we re-attempt a failing message fetch before giving up. */
const MAX_MESSAGE_FETCH_ATTEMPTS = 5;

/**
 * Page cap per folder per self-heal delta sweep. A walk that exceeds the
 * cap stores its nextLink and resumes on the next cycle, bounding the work
 * any single self-heal run can do.
 */
const MAX_DELTA_PAGES_PER_HEAL = 20;

/**
 * Idempotency window for `onCreateLink`. A compose draft carries no stable
 * id, so we dedupe by a content hash; two dispatches with identical content
 * within this window are treated as a callback retry (suppress the resend),
 * while a genuine re-compose later than this still sends.
 */
const COMPOSE_DEDUP_WINDOW_MS = 10 * 60 * 1000;

/** Direct fileAttachment POST limit; larger files go via upload session. */
const DIRECT_ATTACH_MAX_BYTES = 3 * 1024 * 1024;

/**
 * A message whose probe/fetch failed during an incremental sync and must be
 * re-attempted on a later sync. `attempts` bounds retries so a permanently
 * unfetchable message is eventually abandoned with a log line rather than
 * re-fetched forever.
 */
type PendingMessage = { id: string; attempts: number };

/** Persisted mailbox-wide Graph subscription state. */
type SubscriptionState = {
  subscriptionId: string;
  /** Random secret echoed back in every notification — Graph's only
   * notification-authenticity signal. Verified in the webhook handler. */
  clientState: string;
  /** Webhook callback URL (deleted on teardown to free the token). */
  webhookUrl: string;
  expiration: Date;
  created: string;
};

/** Persisted incremental retry state (notified ids whose fetch failed). */
type IncrementalState = { pendingMessageIds?: PendingMessage[] };

/** Persisted per-channel initial-backfill cursor. */
type InitialSyncState = { nextLink?: string | null; lastSyncTime?: Date };

/** Per-folder delta cursor: nextLink mid-walk or deltaLink at rest. */
type DeltaState = { url: string };

/**
 * FNV-1a 32-bit hash → 8-char hex. Deterministic and dependency-free; used
 * only to derive a compact idempotency key from compose-draft content, not
 * for anything security-sensitive.
 */
function fnv1aHex(input: string): string {
  let h = 0x811c9dc5;
  for (let i = 0; i < input.length; i++) {
    h ^= input.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return (h >>> 0).toString(16).padStart(8, "0");
}

/**
 * Compute the outbound email recipient list for a single role (To or Cc),
 * applying the per-note access_contacts constraint when set.
 *
 * @param args.accessContactEmails - Allowed email addresses derived from
 *   note.accessContacts (contact IDs resolved to emails via thread.accessContacts),
 *   or null when the note has no access restriction (send to everyone).
 * @param args.candidates - Email addresses for this role from the message.
 * @param args.self - Sender email; always excluded regardless of constraint.
 * @returns Filtered list of email addresses for the role.
 */
export function recipientsFor(args: {
  accessContactEmails: Set<string> | null;
  candidates: string[];
  self: string;
}): string[] {
  const { accessContactEmails, candidates, self } = args;
  const selfLower = self.toLowerCase();
  return candidates.filter((email) => {
    const lower = email.toLowerCase();
    if (lower === selfLower) return false; // sender is never a recipient
    if (accessContactEmails === null) return true; // no constraint: include all
    return accessContactEmails.has(lower); // constrained: only allowed contacts
  });
}

/**
 * Pick which enabled channel (folder) a conversation files under. Custom
 * folders are most specific so they win (alphabetical for stability); then
 * inbox; then sentitems; then archive. Returns null when no enabled folder
 * holds any of the conversation's messages (a mailbox-wide change that's
 * irrelevant to the enabled channels — skipped, same as gmail's
 * pickChannelForThread).
 */
export function pickChannelForConversation(
  messages: GraphMessage[],
  enabledChannels: Set<string>,
  wellKnown: WellKnownFolders
): string | null {
  const folders = new Set<string>();
  for (const m of messages) {
    if (m.parentFolderId) folders.add(m.parentFolderId);
  }
  const system = new Set(
    [wellKnown.inbox, wellKnown.sentitems, wellKnown.archive].filter(
      Boolean
    ) as string[]
  );
  const customMatches = [...enabledChannels]
    .filter((id) => !system.has(id) && folders.has(id))
    .sort();
  if (customMatches.length > 0) return customMatches[0];
  for (const id of [wellKnown.inbox, wellKnown.sentitems, wellKnown.archive]) {
    if (id && enabledChannels.has(id) && folders.has(id)) return id;
  }
  return null;
}

/** Standard-base64 encode (chunked to avoid call-stack limits on big files). */
function uint8ToBase64(bytes: Uint8Array): string {
  const CHUNK = 32768;
  let binary = "";
  for (let i = 0; i < bytes.length; i += CHUNK) {
    const slice = bytes.subarray(i, i + CHUNK);
    for (let j = 0; j < slice.length; j++) {
      binary += String.fromCharCode(slice[j]);
    }
  }
  return btoa(binary);
}

type ConversationItem = {
  messages: GraphMessage[];
  attachmentsByMessageId: Map<string, GraphAttachmentMeta[]>;
  parentHeaders: GraphHeader[] | null;
};

/**
 * Microsoft Outlook Mail connector.
 *
 * Channels are mail folders; enabling one backfills its history. Ongoing
 * changes arrive through a single mailbox-wide Graph change-notification
 * subscription on `/me/messages`, with an hourly per-folder delta-query
 * self-heal sweeping up anything push delivery missed.
 *
 * **Required OAuth Scopes:**
 * - `Mail.ReadWrite` — read folders/messages, update read + flag state, drafts
 * - `Mail.Send` — send replies and new mail composed in Plot
 * - `People.Read` / `Contacts.Read` — display-name enrichment (best-effort)
 */
export class OutlookMail extends Connector<OutlookMail> {
  static readonly PROVIDER = AuthProvider.Microsoft;
  static readonly handleReplies = true;
  static readonly SCOPES = [
    "https://graph.microsoft.com/mail.readwrite",
    "https://graph.microsoft.com/mail.send",
  ];

  readonly provider = AuthProvider.Microsoft;
  readonly channelNoun = { singular: "folder", plural: "folders" };
  // Merge in People/Contacts scopes so email-only contacts (Graph messages
  // carry name + address but nothing else) can be enriched with display
  // names from the user's People/Contacts data.
  readonly scopes = Integrations.MergeScopes(
    OutlookMail.SCOPES,
    OUTLOOK_PEOPLE_SCOPES
  );
  readonly linkTypes = [
    {
      type: "email",
      label: "Thread",
      noteLabel: "Reply",
      sharingModel: "message" as const,
      composePlaceholder: "Send an Outlook email",
      composeVerb: "Send",
      replyPlaceholder: "Reply",
      replyVerb: "Send",
      supportsFileAttachments: true,
      logo: "https://api.iconify.design/logos/microsoft-icon.svg",
      logoDark:
        "https://api.iconify.design/simple-icons/microsoftoutlook.svg?color=%230078D4",
      logoMono: "https://api.iconify.design/simple-icons/microsoftoutlook.svg",
      contactRoles: [
        { id: "to", label: "To", default: true },
        { id: "cc", label: "CC" },
        { id: "bcc", label: "BCC", hidden: true },
      ],
      supportsContactChanges: true,
      // Outlook composes target any address — a Plot contact (with or
      // without a connection-scoped row) or a free-form typed email
      // delivered via `inviteEmails`.
      compose: {
        targets: "addresses" as const,
      },
    },
  ];

  build(build: ToolBuilder) {
    return {
      integrations: build(Integrations),
      network: build(Network, {
        urls: ["https://graph.microsoft.com/*"],
      }),
      files: build(Files),
    };
  }

  override async activate(context: {
    auth: Authorization;
    actor: Actor;
  }): Promise<void> {
    await this.set("auth_actor_id", context.actor.id);
  }

  async getChannels(
    _auth: Authorization,
    token: AuthToken
  ): Promise<Channel[]> {
    const api = new GraphMailApi(token.token);
    const folders = await api.getMailFolders();
    const wellKnown = await api.getWellKnownFolderIds();
    // Cache for sync paths (channel routing, excluded-folder filtering).
    await this.set("wellknown_folders", wellKnown);

    const excluded = new Set(
      EXCLUDED_WELL_KNOWN.map((n) => wellKnown[n]).filter(Boolean) as string[]
    );
    return folders
      .filter((f) => !excluded.has(f.id) && !f.isHidden)
      .map((f) => ({
        id: f.id,
        title: f.displayName,
        // Default to the user's actual conversations: incoming + outgoing.
        enabledByDefault:
          f.id === wellKnown.inbox || f.id === wellKnown.sentitems,
      }));
  }

  async onChannelEnabled(
    channel: Channel,
    context?: SyncContext
  ): Promise<void> {
    const syncHistoryMin = context?.syncHistoryMin;
    if (context?.recovering) {
      // Recovery dispatch after re-auth: drop the per-channel cursors so
      // this channel re-walks its folder and the delta baseline reseeds.
      await this.clear(`initial_state_${channel.id}`);
      await this.clear(`delta_${channel.id}`);
    } else if (syncHistoryMin) {
      // Skip when stored window is already at least as wide. Bypassed on
      // recovery so the recovery pass re-walks even when the window
      // hasn't widened.
      const storedMin = await this.get<string>(
        `sync_history_min_${channel.id}`
      );
      if (storedMin && new Date(storedMin) <= syncHistoryMin) {
        return;
      }
      await this.set(
        `sync_history_min_${channel.id}`,
        syncHistoryMin.toISOString()
      );
    }

    await this.addEnabledChannel(channel.id);

    // observeOnly: the channel is being auto-observed because a user composed
    // a Plot thread into it, not explicitly enabled. We still register the
    // mailbox subscription below so inbound events sync back, but skip the
    // historical backfill — the user didn't ask to import this folder's
    // history.
    if (!context?.observeOnly) {
      const initialState: InitialSyncState = {
        lastSyncTime: syncHistoryMin ?? undefined,
      };
      await this.set(`initial_state_${channel.id}`, initialState);

      const initialCallback = await this.callback(
        this.initialSyncBatch,
        channel.id,
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

  async onChannelDisabled(channel: Channel): Promise<void> {
    await this.removeEnabledChannel(channel.id);
    await this.clear(`initial_state_${channel.id}`);
    await this.clear(`sync_history_min_${channel.id}`);
    await this.clear(`delta_${channel.id}`);

    // If no enabled channels remain, tear the subscription down. The next
    // onChannelEnabled will rebuild it.
    const enabled = await this.getEnabledChannels();
    if (enabled.size === 0) {
      await this.teardownMailboxSubscription();
    }
  }

  /** Legacy entry point kept for interface parity with gmail. */
  async startSync(options: { channelId: string; timeMin?: Date }): Promise<void> {
    const { channelId, timeMin } = options;
    await this.set(`initial_state_${channelId}`, {
      lastSyncTime: timeMin ?? undefined,
    } satisfies InitialSyncState);
    await this.addEnabledChannel(channelId);
    await this.runTask(await this.callback(this.initialSyncBatch, channelId, 1));
    await this.runTask(await this.callback(this.ensureMailboxSubscription));
  }

  async stopSync(channelId: string): Promise<void> {
    await this.removeEnabledChannel(channelId);
    await this.clear(`initial_state_${channelId}`);
    await this.clear(`delta_${channelId}`);
    const enabled = await this.getEnabledChannels();
    if (enabled.size === 0) {
      await this.teardownMailboxSubscription();
    }
  }

  // Auth + channel helpers ---------------------------------------------------

  private async getApi(channelId: string): Promise<GraphMailApi> {
    const token = await this.tools.integrations.get(channelId);
    if (!token) {
      throw new Error("No Microsoft authentication token available");
    }
    return new GraphMailApi(token.token);
  }

  /**
   * Returns a Graph client authed with any enabled channel's token. Auth is
   * per-Microsoft-account (not per-folder), so any enabled channelId
   * resolves to the same OAuth credential.
   */
  private async getApiAny(): Promise<GraphMailApi | null> {
    const enabled = await this.getEnabledChannels();
    for (const channelId of enabled) {
      const token = await this.tools.integrations.get(channelId);
      if (token?.token) return new GraphMailApi(token.token);
    }
    return null;
  }

  /** Returns the set of channelIds the user currently has enabled. */
  private async getEnabledChannels(): Promise<Set<string>> {
    const list = (await this.get<string[]>("enabled_channels")) ?? [];
    return new Set(list);
  }

  private async addEnabledChannel(channelId: string): Promise<void> {
    const list = (await this.get<string[]>("enabled_channels")) ?? [];
    if (list.includes(channelId)) return;
    list.push(channelId);
    await this.set("enabled_channels", list);
  }

  private async removeEnabledChannel(channelId: string): Promise<void> {
    const list = (await this.get<string[]>("enabled_channels")) ?? [];
    const filtered = list.filter((c) => c !== channelId);
    if (filtered.length === list.length) return;
    await this.set("enabled_channels", filtered);
  }

  private async isChannelEnabled(channelId: string): Promise<boolean> {
    const list = (await this.get<string[]>("enabled_channels")) ?? [];
    return list.includes(channelId);
  }

  /** The connected mailbox's address, fetched once and cached. */
  private async ensureUserEmail(api?: GraphMailApi): Promise<string> {
    const stored = await this.get<string>("user_email");
    if (stored) return stored;
    const client = api ?? (await this.getApiAny());
    if (!client) return "";
    const profile = await client.getProfile();
    if (profile.email) await this.set("user_email", profile.email);
    return profile.email;
  }

  /** Well-known folder map, cached by getChannels and refreshed on demand. */
  private async getWellKnown(api?: GraphMailApi): Promise<WellKnownFolders> {
    const stored = await this.get<WellKnownFolders>("wellknown_folders");
    if (stored && Object.keys(stored).length > 0) return stored;
    const client = api ?? (await this.getApiAny());
    if (!client) return {};
    const fresh = await client.getWellKnownFolderIds();
    await this.set("wellknown_folders", fresh);
    return fresh;
  }

  // Subscription lifecycle ----------------------------------------------------

  /**
   * Idempotently set up the mailbox-wide Graph subscription. Called every
   * time a channel is enabled; first call creates it, subsequent calls only
   * make sure the self-heal cycle is running.
   */
  async ensureMailboxSubscription(): Promise<void> {
    const existing = await this.get<SubscriptionState>("mailbox_subscription");
    if (!existing) {
      await this.setupMailboxSubscription();
      return;
    }
    const existingSelfHeal = await this.get<string>("mailbox_self_heal_task");
    if (!existingSelfHeal) {
      await this.scheduleSelfHealCheck();
    }
  }

  private async setupMailboxSubscription(): Promise<void> {
    // Replace any prior subscription: delete the server-side subscription
    // and webhook token, then create fresh (mirrors gmail's
    // setupMailboxWebhook cleanup so renewals never leak resources).
    const existing = await this.get<SubscriptionState>("mailbox_subscription");
    await this.clear("mailbox_subscription");
    if (existing?.subscriptionId) {
      const cleanupApi = await this.getApiAny();
      if (cleanupApi) {
        try {
          await cleanupApi.deleteSubscription(existing.subscriptionId);
        } catch (error) {
          console.warn(
            `OutlookMail setup [${this.id}]: stale subscription delete failed`,
            error
          );
        }
      }
    }
    if (existing?.webhookUrl) {
      try {
        await this.tools.network.deleteWebhook(existing.webhookUrl);
      } catch (error) {
        console.warn(
          `OutlookMail setup [${this.id}]: stale webhook delete failed`,
          error
        );
      }
    }

    // Synchronous webhook: Graph validates the endpoint inline by POSTing
    // ?validationToken=... and expecting a text/plain echo — the async queue
    // default would reply `200 { queued: true }` and creation would fail.
    const webhookUrl = await this.tools.network.createWebhook(
      { async: false },
      this.onOutlookMailWebhook
    );
    if (webhookUrl.includes("localhost") || webhookUrl.includes("127.0.0.1")) {
      console.log(
        `OutlookMail setup [${this.id}]: localhost webhook — skipping subscription`
      );
      return;
    }

    const api = await this.getApiAny();
    if (!api) {
      console.warn(
        `OutlookMail setup [${this.id}]: no enabled channel to source auth from`
      );
      return;
    }

    const clientState = crypto.randomUUID();
    const expirationDateTime = new Date(
      Date.now() + SUBSCRIPTION_DURATION_DAYS * 24 * 60 * 60 * 1000
    );
    const sub = await api.createSubscription({
      notificationUrl: webhookUrl,
      clientState,
      expirationDateTime,
    });

    const expiration = new Date(sub.expirationDateTime);
    await this.set<SubscriptionState>("mailbox_subscription", {
      subscriptionId: sub.id,
      clientState,
      webhookUrl,
      expiration,
      created: new Date().toISOString(),
    });
    await this.scheduleMailboxRenewal(expiration);
    await this.scheduleSelfHealCheck();
    console.log(`OutlookMail setup [${this.id}]: subscription established`, {
      subscriptionId: sub.id,
      expiration: expiration.toISOString(),
    });
  }

  /**
   * Cancel renewal + self-heal tasks, delete the Graph subscription and the
   * webhook token, and clear all subscription state. Called when the last
   * channel is disabled.
   */
  private async teardownMailboxSubscription(): Promise<void> {
    const renewalTaskToken = await this.get<string>("mailbox_renewal_task");
    if (renewalTaskToken) {
      try {
        await this.cancelTask(renewalTaskToken);
      } catch {
        // Task may have already executed
      }
      await this.clear("mailbox_renewal_task");
    }

    const selfHealTaskToken = await this.get<string>("mailbox_self_heal_task");
    if (selfHealTaskToken) {
      try {
        await this.cancelTask(selfHealTaskToken);
      } catch {
        // Task may have already executed
      }
      await this.clear("mailbox_self_heal_task");
    }

    const subscription = await this.get<SubscriptionState>(
      "mailbox_subscription"
    );
    if (subscription?.subscriptionId) {
      const api = await this.getApiAny();
      if (api) {
        try {
          await api.deleteSubscription(subscription.subscriptionId);
        } catch (error) {
          console.error(
            `OutlookMail teardown [${this.id}]: deleteSubscription failed`,
            error
          );
        }
      }
    }
    if (subscription?.webhookUrl) {
      try {
        await this.tools.network.deleteWebhook(subscription.webhookUrl);
      } catch (error) {
        console.error(
          `OutlookMail teardown [${this.id}]: deleteWebhook failed`,
          error
        );
      }
    }
    await this.clear("mailbox_subscription");
    await this.clear("incremental_state");
    await this.clear("last_webhook_received_at");
  }

  /** Schedules subscription renewal RENEWAL_LEAD_MS before expiry. */
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

    const renewalTime = new Date(expiration.getTime() - RENEWAL_LEAD_MS);
    if (renewalTime <= new Date()) {
      await this.renewMailboxSubscription();
      return;
    }

    const renewalCallback = await this.callback(this.renewMailboxSubscription);
    const taskToken = await this.runTask(renewalCallback, {
      runAt: renewalTime,
    });
    if (taskToken) {
      await this.set("mailbox_renewal_task", taskToken);
    }
  }

  /**
   * Renews the Graph subscription before it expires (PATCH keeps the
   * subscription id and clientState stable). On primary-path failure, falls
   * back to a full delete-and-recreate. If both paths fail the error is
   * rethrown so the runtime captures it in PostHog — `selfHealCheck` is the
   * safety net that retries on the next interval.
   */
  async renewMailboxSubscription(): Promise<void> {
    let primaryError: unknown;
    try {
      const api = await this.getApiAny();
      if (!api) {
        console.warn(
          `OutlookMail renew [${this.id}]: no enabled channel to source auth from`
        );
        return;
      }

      const subscription = await this.get<SubscriptionState>(
        "mailbox_subscription"
      );
      if (!subscription?.subscriptionId) {
        await this.setupMailboxSubscription();
        return;
      }

      const newExpiry = new Date(
        Date.now() + SUBSCRIPTION_DURATION_DAYS * 24 * 60 * 60 * 1000
      );
      await api.renewSubscription(subscription.subscriptionId, newExpiry);
      await this.set<SubscriptionState>("mailbox_subscription", {
        ...subscription,
        expiration: newExpiry,
      });
      await this.scheduleMailboxRenewal(newExpiry);
      await this.scheduleSelfHealCheck();
      console.log(`OutlookMail renew [${this.id}]: subscription renewed`, {
        expiration: newExpiry.toISOString(),
      });
      return;
    } catch (error) {
      primaryError = error;
      console.error(
        `OutlookMail renew [${this.id}]: renewal failed, attempting full recreate`,
        error
      );
    }

    try {
      await this.setupMailboxSubscription();
    } catch (retryError) {
      console.error(
        `OutlookMail renew [${this.id}]: fallback setup also failed`,
        { primaryError, retryError }
      );
      throw retryError instanceof Error
        ? retryError
        : new Error(String(retryError));
    }
  }

  /**
   * (Re)schedules the next self-heal check. Cancels any existing task so
   * there's at most one outstanding self-heal task at a time.
   */
  private async scheduleSelfHealCheck(): Promise<void> {
    const existing = await this.get<string>("mailbox_self_heal_task");
    if (existing) {
      try {
        await this.cancelTask(existing);
      } catch {
        // Task may have already executed.
      }
      await this.clear("mailbox_self_heal_task");
    }

    const callback = await this.callback(this.selfHealCheck);
    const taskToken = await this.runTask(callback, {
      runAt: new Date(Date.now() + SELF_HEAL_INTERVAL_MS),
    });
    if (taskToken) {
      await this.set("mailbox_self_heal_task", taskToken);
    }
  }

  /**
   * Periodic safety net. Each run (1) sweeps per-folder delta queries to
   * ingest anything push delivery missed, (2) verifies the subscription
   * isn't missing/expired/imminent, and (3) logs a heartbeat. Always
   * reschedules itself, so a single failed run never breaks the cycle.
   *
   * Unlike gmail (whose history cursor advances on every webhook, making
   * any history found here proof that push broke), our delta cursors only
   * advance during this sweep — so delta results overlap with mail the
   * webhook path already processed. That re-processing is idempotent
   * (source/key upserts, cached unread/flag state), and it is NOT treated
   * as evidence the subscription is broken; re-subscription is driven only
   * by the subscription's own expiry state.
   */
  async selfHealCheck(): Promise<void> {
    const now = new Date();

    const enabled = await this.getEnabledChannels();
    if (enabled.size === 0) {
      await this.clear("mailbox_self_heal_task");
      console.log(
        `OutlookMail selfHealCheck [${this.id}]: no enabled channels, ending cycle`
      );
      return;
    }

    let unrecoverableError: unknown;
    let action: "healthy" | "renewed" | "recreated" = "healthy";
    let sweptMessages = 0;

    const subscription = await this.get<SubscriptionState>(
      "mailbox_subscription"
    );
    const lastWebhookAt = await this.get<string>("last_webhook_received_at");

    // 1. Delta sweep per enabled folder. Works even when the subscription
    //    is broken because we're polling delta directly.
    try {
      const api = await this.getApiAny();
      if (api) {
        const changed = new Set<string>();
        for (const folderId of enabled) {
          try {
            for (const id of await this.folderDeltaCatchUp(api, folderId)) {
              changed.add(id);
            }
          } catch (error) {
            console.error(
              `OutlookMail selfHealCheck [${this.id}]: delta sweep failed for ${folderId}`,
              error
            );
          }
        }
        if (changed.size > 0) {
          sweptMessages = changed.size;
          await this.incrementalSyncBatch([...changed]);
        }
      }
    } catch (error) {
      // Sweep is best-effort; don't let it abort subscription verification.
      console.error(
        `OutlookMail selfHealCheck [${this.id}]: delta sweep failed`,
        error
      );
    }

    // 2. Verify subscription state. Recreate/renew if missing/expired/imminent.
    let needsReup = false;
    if (!subscription) {
      needsReup = true;
      action = "recreated";
    } else {
      const expirationDate = new Date(subscription.expiration);
      const msToExpiry = expirationDate.getTime() - now.getTime();
      if (msToExpiry < 0) {
        needsReup = true;
        action = "recreated";
        console.warn(
          `OutlookMail selfHealCheck [${this.id}]: subscription expired ${-msToExpiry}ms ago`
        );
      } else if (msToExpiry < SUB_PREEMPTIVE_RENEW_MS) {
        needsReup = true;
        action = "renewed";
      }
    }

    if (needsReup) {
      try {
        if (action === "renewed") {
          await this.renewMailboxSubscription();
        } else {
          await this.setupMailboxSubscription();
        }
      } catch (error) {
        unrecoverableError = error;
        console.error(
          `OutlookMail selfHealCheck [${this.id}]: subscription re-up failed`,
          error
        );
      }
    }

    console.log(`OutlookMail selfHealCheck [${this.id}]: ${action}`, {
      sweptMessages,
      enabledChannels: Array.from(enabled),
      subscriptionId: subscription?.subscriptionId ?? null,
      subscriptionExpiration: subscription?.expiration
        ? new Date(subscription.expiration).toISOString()
        : null,
      lastWebhookAt: lastWebhookAt ?? null,
      minutesSinceLastWebhook: lastWebhookAt
        ? Math.round(
            (now.getTime() - new Date(lastWebhookAt).getTime()) / 60000
          )
        : null,
      now: now.toISOString(),
    });

    // 3. Always reschedule next run, even on failure.
    try {
      await this.scheduleSelfHealCheck();
    } catch (rescheduleError) {
      console.error(
        `OutlookMail selfHealCheck [${this.id}]: reschedule failed`,
        rescheduleError
      );
      if (!unrecoverableError) {
        unrecoverableError = rescheduleError;
      }
    }

    if (unrecoverableError) {
      throw unrecoverableError instanceof Error
        ? unrecoverableError
        : new Error(String(unrecoverableError));
    }
  }

  /**
   * Delta catch-up for one enabled folder. First run seeds the delta
   * baseline filtered to `now` (cheap — establishes a cursor without
   * walking history; the initial backfill already imported history).
   * Subsequent runs walk changes since the stored link. Returns changed
   * message ids. On 410 the cursor is cleared and reseeds next cycle
   * (bounded gap; the webhook path still covers new mail).
   */
  private async folderDeltaCatchUp(
    api: GraphMailApi,
    folderId: string
  ): Promise<string[]> {
    const stored = await this.get<DeltaState>(`delta_${folderId}`);
    let url = stored?.url ?? api.buildInitialDeltaUrl(folderId, new Date());
    const seeding = !stored;
    const changed: string[] = [];
    for (let page = 0; page < MAX_DELTA_PAGES_PER_HEAL; page++) {
      let result;
      try {
        result = await api.deltaPage(url);
      } catch (error) {
        if (error instanceof GraphMailApiError && error.status === 410) {
          await this.clear(`delta_${folderId}`); // reseed next cycle
          return changed;
        }
        throw error;
      }
      if (!seeding) {
        for (const m of result.messages) {
          if (m.id && !(m as Record<string, unknown>)["@removed"]) {
            changed.push(m.id);
          }
        }
      }
      if (result.deltaLink) {
        await this.set<DeltaState>(`delta_${folderId}`, {
          url: result.deltaLink,
        });
        return changed;
      }
      if (!result.nextLink) return changed;
      url = result.nextLink;
      // Persist mid-walk so a page-capped (or crashed) walk resumes here.
      await this.set<DeltaState>(`delta_${folderId}`, { url });
    }
    return changed;
  }

  // Sync pipeline --------------------------------------------------------------

  /**
   * Per-channel initial backfill. Walks the folder's messages newest-first
   * and processes whole conversations. Used the FIRST time a channel is
   * enabled; ongoing changes flow through `incrementalSyncBatch` instead.
   */
  async initialSyncBatch(channelId: string, batchNumber: number): Promise<void> {
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
      const api = new GraphMailApi(token.token);
      if (batchNumber === 1) {
        await this.ensureUserEmail(api);
      }

      const storedMin = await this.get<string>(
        `sync_history_min_${channelId}`
      );
      const page = await api.getMessagesPage(
        cursor.nextLink
          ? { nextLink: cursor.nextLink }
          : {
              folderId: channelId,
              top: 20,
              since: storedMin ? new Date(storedMin) : undefined,
            }
      );

      // One conversation may surface on multiple pages (one message per
      // page); the re-save is an idempotent upsert on source/note.key.
      const conversationIds = [
        ...new Set(
          page.messages
            .filter((m) => !m.isDraft && m.conversationId)
            .map((m) => m.conversationId!)
        ),
      ];
      if (conversationIds.length > 0) {
        const items = await this.fetchConversations(api, conversationIds);
        await this.processConversations(items, true, channelId);
      }

      if (page.nextLink) {
        await this.set<InitialSyncState>(`initial_state_${channelId}`, {
          nextLink: page.nextLink,
          lastSyncTime: cursor.lastSyncTime,
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
   * Fetch full conversations (messages + attachment metadata + the parent's
   * raw headers for facets). Per-conversation failures are logged and
   * skipped — incremental retries happen at the notified-message level.
   */
  private async fetchConversations(
    api: GraphMailApi,
    conversationIds: string[]
  ): Promise<ConversationItem[]> {
    const items: ConversationItem[] = [];
    for (const conversationId of conversationIds) {
      try {
        const messages = await api.getConversationMessages(conversationId);
        if (messages.length === 0) continue;
        const attachmentsByMessageId = new Map<string, GraphAttachmentMeta[]>();
        for (const m of messages) {
          if (!m.isDraft && m.hasAttachments) {
            try {
              attachmentsByMessageId.set(m.id, await api.listAttachments(m.id));
            } catch (error) {
              console.warn(
                `[outlook-mail] attachments fetch failed for ${m.id}:`,
                error
              );
            }
          }
        }
        const parent = messages.find((m) => !m.isDraft);
        let parentHeaders: GraphHeader[] | null = null;
        if (parent) {
          try {
            parentHeaders = await api.getInternetMessageHeaders(parent.id);
          } catch {
            // Facets degrade to header-less signals.
          }
        }
        items.push({ messages, attachmentsByMessageId, parentHeaders });
      } catch (error) {
        console.error(
          `[outlook-mail] failed to fetch conversation ${conversationId}:`,
          error
        );
      }
    }
    return items;
  }

  /**
   * Graph change-notification handler (synchronous webhook). Echoes the
   * validation handshake, verifies clientState, and queues the notified
   * message ids for incremental processing.
   */
  async onOutlookMailWebhook(request: WebhookRequest): Promise<string | void> {
    // Graph endpoint validation handshake — echo as text/plain (sync route).
    if (request.params?.validationToken) {
      return request.params.validationToken as string;
    }

    // Record receipt before any early returns so `selfHealCheck` can
    // distinguish "subscription healthy, just no new mail" from "we haven't
    // heard from Graph in hours".
    await this.set("last_webhook_received_at", new Date().toISOString());

    // Self-heal bootstrap for instances whose cycle died. Idempotent.
    const selfHealTask = await this.get<string>("mailbox_self_heal_task");
    if (!selfHealTask) {
      try {
        await this.scheduleSelfHealCheck();
      } catch (error) {
        console.error(
          `OutlookMail webhook [${this.id}]: self-heal bootstrap failed`,
          error
        );
      }
    }

    const body = request.body as {
      value?: Array<{
        clientState?: string;
        lifecycleEvent?: string;
        resourceData?: { id?: string };
      }>;
    } | null;
    const notifications = body?.value ?? [];
    if (notifications.length === 0) return;

    const stored = await this.get<SubscriptionState>("mailbox_subscription");
    const ids = new Set<string>();
    let lifecycleAction = false;
    for (const n of notifications) {
      // clientState is Graph's only notification-authenticity signal.
      if (!stored?.clientState || n.clientState !== stored.clientState) {
        console.warn(
          `OutlookMail webhook [${this.id}]: clientState mismatch, dropping notification`
        );
        continue;
      }
      if (
        n.lifecycleEvent === "subscriptionRemoved" ||
        n.lifecycleEvent === "reauthorizationRequired"
      ) {
        lifecycleAction = true;
        continue;
      }
      if (n.resourceData?.id) ids.add(n.resourceData.id);
    }
    if (lifecycleAction) {
      await this.runTask(await this.callback(this.renewMailboxSubscription));
    }
    if (ids.size > 0) {
      await this.runTask(
        await this.callback(this.incrementalSyncBatch, [...ids])
      );
    }
  }

  /**
   * Mailbox-wide incremental sync over a set of notified message ids.
   * Probes each message, skips drafts and excluded folders, then fetches
   * and processes whole conversations. Failed probes are carried in
   * `incremental_state.pendingMessageIds` for retry on a later sync.
   */
  async incrementalSyncBatch(messageIds: string[]): Promise<void> {
    try {
      const enabled = await this.getEnabledChannels();
      if (enabled.size === 0) return;
      const api = await this.getApiAny();
      if (!api) {
        console.warn(
          "[outlook-mail] incrementalSyncBatch: no enabled channel to source auth from"
        );
        return;
      }

      const state =
        (await this.get<IncrementalState>("incremental_state")) ?? {};
      const pending = state.pendingMessageIds ?? [];
      const toFetch = [
        ...new Set([...messageIds, ...pending.map((p) => p.id)]),
      ];

      const wellKnown = await this.getWellKnown(api);
      const excludedFolderIds = new Set(
        EXCLUDED_WELL_KNOWN.map((n) => wellKnown[n]).filter(Boolean) as string[]
      );

      const conversationIds = new Set<string>();
      const failedIds: string[] = [];
      for (const id of toFetch) {
        try {
          const m = await api.getMessage(
            id,
            "id,conversationId,parentFolderId,isDraft"
          );
          if (!m) continue; // 404 — hard-deleted upstream; nothing to ingest
          if (m.isDraft) continue;
          if (m.parentFolderId && excludedFolderIds.has(m.parentFolderId)) {
            continue;
          }
          if (m.conversationId) conversationIds.add(m.conversationId);
        } catch (error) {
          console.error(`[outlook-mail] message probe failed for ${id}:`, error);
          failedIds.push(id);
        }
      }

      const items = await this.fetchConversations(api, [...conversationIds]);
      if (items.length > 0) {
        await this.processConversations(items, false);
      }

      await this.set<IncrementalState>("incremental_state", {
        pendingMessageIds: this.mergePendingMessages(pending, failedIds),
      });
    } catch (error) {
      console.error("[outlook-mail] incremental sync batch failed:", error);
      throw error;
    }
  }

  /**
   * Merges newly-failed message fetches into the prior pending set, bumping
   * a per-message attempt counter and dropping messages that have exhausted
   * {@link MAX_MESSAGE_FETCH_ATTEMPTS} retries (logged, since that change is
   * effectively lost). Messages that succeeded this round are simply absent
   * from `failedIds` and therefore fall out of the pending set.
   */
  private mergePendingMessages(
    prior: PendingMessage[],
    failedIds: string[]
  ): PendingMessage[] {
    const attemptsById = new Map(prior.map((p) => [p.id, p.attempts]));
    const merged: PendingMessage[] = [];
    for (const id of failedIds) {
      const attempts = (attemptsById.get(id) ?? 0) + 1;
      if (attempts > MAX_MESSAGE_FETCH_ATTEMPTS) {
        console.error(
          `[outlook-mail] giving up on message ${id} after ${attempts - 1} failed fetch attempts; its change may be lost`
        );
        continue;
      }
      merged.push({ id, attempts });
    }
    return merged;
  }

  private async processConversations(
    items: ConversationItem[],
    initialSync: boolean,
    forceChannelId?: string
  ): Promise<void> {
    const enabledChannels = forceChannelId
      ? new Set([forceChannelId])
      : await this.getEnabledChannels();
    if (enabledChannels.size === 0) return;

    const accountEmail = await this.ensureUserEmail();
    const wellKnown = await this.getWellKnown();

    // Pre-build all plot threads, then enrich contact names across the
    // batch in one People/Contacts pass.
    const transformed: {
      item: ConversationItem;
      plot: NewLinkWithNotes;
      channelId: string;
      conversationId: string;
    }[] = [];
    for (const item of items) {
      const plot = transformOutlookConversation({
        messages: item.messages,
        attachmentsByMessageId: item.attachmentsByMessageId,
        accountEmail,
      });
      if (!plot.notes || plot.notes.length === 0) continue;

      const chosen =
        forceChannelId ??
        pickChannelForConversation(item.messages, enabledChannels, wellKnown);
      if (!chosen) continue; // Conversation doesn't match any enabled channel.

      transformed.push({
        item,
        plot,
        channelId: chosen,
        conversationId: plot.meta!.conversationId as string,
      });
    }
    if (transformed.length === 0) return;

    // Auth scope is per-account, not per-channel; any enabled channel ID
    // sources the same token.
    const authChannelId = forceChannelId ?? transformed[0].channelId;
    try {
      const token = await this.tools.integrations.get(authChannelId);
      if (token) {
        await enrichLinkContactsFromOutlook(
          transformed.map((t) => t.plot),
          token.token,
          token.scopes
        );
      }
    } catch (err) {
      // Enrichment is best-effort — Gravatar fallback in the client still
      // covers anyone the People API doesn't return.
      console.warn("Failed to enrich Outlook contacts (non-blocking):", err);
    }

    for (const { item, plot: plotThread, channelId, conversationId } of transformed) {
      try {
        // Cache message → channel mapping so downloadAttachment can find
        // auth for a given Graph message id.
        for (const message of item.messages) {
          if (!message.isDraft) {
            await this.set(`outlook:msg-channel:${message.id}`, channelId);
          }
        }

        // Filter out notes for messages we sent from Plot (echo dedup).
        const filtered = [];
        for (const note of plotThread.notes!) {
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

        const isUnread = isConversationUnread(item.messages);
        if (initialSync) {
          plotThread.unread = false;
          plotThread.archived = false;
          await this.set(`unread:${conversationId}`, isUnread);
        } else {
          const wasUnread = await this.get<boolean>(`unread:${conversationId}`);
          if (wasUnread == null) {
            // First time seeing this conversation incrementally. If it is
            // already read in Outlook, align Plot's state.
            if (!isUnread) {
              plotThread.unread = false;
            }
          } else if (isUnread !== wasUnread) {
            // The unread state changed in Outlook, so write it to Plot.
            plotThread.unread = isUnread;
          }
          await this.set(`unread:${conversationId}`, isUnread);
        }

        // Inject channel ID for priority routing and sync metadata.
        plotThread.channelId = channelId;
        plotThread.meta = {
          ...plotThread.meta,
          syncProvider: "microsoft",
          syncableId: channelId,
          channelId,
        };

        // Compute classifier facets from the parent message's headers + body.
        const facetParent = sortConversation(item.messages).find(
          (m) => !m.isDraft
        );
        if (facetParent) {
          const parentKey = facetParent.internetMessageId ?? facetParent.id;
          const facetNote = plotThread.notes?.find(
            (n) => "key" in n && (n as { key: string }).key === parentKey
          );
          const facetBody =
            (facetNote as { content?: string } | undefined)?.content ??
            plotThread.preview ??
            "";
          plotThread.facets = outlookFacets(
            item.parentHeaders,
            facetParent,
            facetBody
          );
        }

        const isFlagged = isConversationFlagged(item.messages);
        const savedThreadId =
          await this.tools.integrations.saveLink(plotThread);
        if (!savedThreadId) continue; // Link was filtered (e.g., older than sync history)

        const wasFlagged = await this.get<boolean>(`flagged:${conversationId}`);

        // Echo suppression relies entirely on the `flagged` state: when
        // Plot→Outlook writes the flag, onThreadToDo updates this state
        // *before* the API call. The resulting Graph notification sees
        // isFlagged === wasFlagged and this branch doesn't run.
        if (isFlagged !== !!wasFlagged) {
          const actorId = await this.get<ActorId>("auth_actor_id");
          if (actorId) {
            await this.tools.integrations.setThreadToDo(
              plotThread.source as string,
              actorId,
              isFlagged
            );
            // Prevent the onThreadToDo callback from echoing back.
            await this.set(`skip_todo_writeback:${conversationId}`, true);
          }
          await this.set(`flagged:${conversationId}`, isFlagged);
        }
      } catch (error) {
        console.error(
          `Failed to process Outlook conversation ${conversationId}:`,
          error
        );
        // Continue processing other conversations.
      }
    }
  }

  // Two-way status sync ---------------------------------------------------------

  async onThreadRead(
    thread: Thread,
    _actor: Actor,
    unread: boolean
  ): Promise<void> {
    const meta = thread.meta ?? {};
    const channelId = (meta.channelId ?? meta.syncableId) as string;
    const conversationId = meta.conversationId as string;
    if (!channelId || !conversationId) return;

    const api = await this.getApi(channelId);

    // Cache the new state before the Graph writes so the resulting change
    // notifications see state === cache and don't re-propagate.
    await this.set(`unread:${conversationId}`, unread);

    const messages = (
      await api.getConversationMessages(conversationId)
    ).filter((m) => !m.isDraft);
    if (messages.length === 0) return;

    if (unread) {
      // Mark the latest message unread — matches Outlook's own conversation
      // unread affordance without resurrecting every old message.
      await api.updateMessage(messages[messages.length - 1].id, {
        isRead: false,
      });
    } else {
      for (const m of messages) {
        if (m.isRead === false) {
          await api.updateMessage(m.id, { isRead: true });
        }
      }
    }
  }

  async onThreadToDo(
    thread: Thread,
    _actor: Actor,
    todo: boolean,
    _options: { date?: Date }
  ): Promise<void> {
    const meta = thread.meta ?? {};
    const conversationId = meta.conversationId as string;
    const channelId = (meta.channelId ?? meta.syncableId) as string;
    if (!conversationId || !channelId) return;

    // Loop prevention: skip if this change originated from Outlook flag sync.
    if (await this.get(`skip_todo_writeback:${conversationId}`)) {
      await this.clear(`skip_todo_writeback:${conversationId}`);
      return;
    }

    // Update local state BEFORE calling Graph, so the notification fired by
    // our own write sees isFlagged === wasFlagged and doesn't re-propagate.
    await this.set(`flagged:${conversationId}`, todo);

    const api = await this.getApi(channelId);
    const messages = (
      await api.getConversationMessages(conversationId)
    ).filter((m) => !m.isDraft);
    if (messages.length === 0) return;

    if (todo) {
      await api.updateMessage(messages[messages.length - 1].id, {
        flag: { flagStatus: "flagged" },
      });
    } else {
      for (const m of messages) {
        if (m.flag?.flagStatus === "flagged") {
          await api.updateMessage(m.id, { flag: { flagStatus: "notFlagged" } });
        }
      }
    }
  }

  // Reply + compose ---------------------------------------------------------------

  async onNoteCreated(
    note: Note,
    thread: Thread
  ): Promise<NoteWriteBackResult | void> {
    const meta = thread.meta ?? {};
    const channelId = (meta.channelId ?? meta.syncableId) as string;
    if (!channelId) {
      console.error("No channelId in meta for Outlook reply");
      return;
    }
    const conversationId = meta.conversationId as string;
    if (!conversationId) {
      console.error("No conversationId in meta for Outlook reply");
      return;
    }

    // Idempotency: a callback may be re-dispatched after its send already
    // succeeded. `note.id` is stable across retries of the same note.
    const sendGuardKey = `send_note:${note.id}`;
    const priorSend = await this.get<{ key: string }>(sendGuardKey);
    if (priorSend?.key) {
      console.log(
        `[outlook-mail] onNoteCreated: note ${note.id} already sent as ${priorSend.key}, skipping resend`
      );
      return { key: priorSend.key };
    }

    const api = await this.getApi(channelId);

    const messages = (
      await api.getConversationMessages(conversationId)
    ).filter((m) => !m.isDraft);
    if (messages.length === 0) {
      console.error("Outlook conversation has no messages");
      return;
    }

    // Determine target message: specific replied-to note or last message.
    let targetMessage = messages[messages.length - 1];
    if (meta.reNoteKey) {
      const found = messages.find(
        (m) => m.internetMessageId === meta.reNoteKey
      );
      if (found) {
        targetMessage = found;
      }
    }

    const senderEmail = (await this.ensureUserEmail(api)).toLowerCase();

    // Build per-note access constraint: when note.accessContacts is set,
    // resolve contact IDs to lowercase email addresses using
    // thread.accessContacts so we can filter the outbound recipient list.
    // null means no constraint (send to all). A note with accessContacts =
    // [self] is a Private note and must not be sent via Outlook at all.
    let accessContactEmails: Set<string> | null = null;
    if (note.accessContacts !== null) {
      const allowedIds = new Set<ActorId>(note.accessContacts);
      accessContactEmails = new Set<string>();
      for (const contact of thread.accessContacts ?? []) {
        if (allowedIds.has(contact.id) && contact.email) {
          accessContactEmails.add(contact.email.toLowerCase());
        }
      }
    }

    // Reply-all candidates: From + To (deduped) become To; Cc stays Cc.
    const allCandidates = new Set<string>();
    for (const email of recipientEmails(
      targetMessage.from ? [targetMessage.from] : []
    )) {
      allCandidates.add(email.toLowerCase());
    }
    for (const email of recipientEmails(targetMessage.toRecipients)) {
      allCandidates.add(email.toLowerCase());
    }
    const ccCandidates = new Set<string>();
    for (const email of recipientEmails(targetMessage.ccRecipients)) {
      ccCandidates.add(email.toLowerCase());
    }

    const toCandidates = Array.from(allCandidates).filter(
      (email) => !ccCandidates.has(email)
    );
    const to = recipientsFor({
      accessContactEmails,
      candidates: toCandidates,
      self: senderEmail,
    });
    const cc = recipientsFor({
      accessContactEmails,
      candidates: Array.from(ccCandidates),
      self: senderEmail,
    });

    if (to.length === 0 && cc.length === 0) {
      if (note.accessContacts !== null) {
        console.log(
          `[outlook-mail] onNoteCreated: note ${note.id} has access_contacts constraint with no outbound recipients; skipping send`
        );
      } else {
        console.error("No recipients for Outlook reply");
      }
      return;
    }

    // Graph threads the reply for us (In-Reply-To / References / subject).
    const draft = await api.createReplyDraft(targetMessage.id);

    // PATCHing the body replaces Outlook's quoted-history block — Plot
    // threads carry the history as notes, and Gmail replies are likewise
    // unquoted.
    const addr = (address: string) => ({ emailAddress: { address } });
    await api.updateMessage(draft.id, {
      body: { contentType: "text", content: note.content ?? "" },
      toRecipients: to.map(addr),
      ccRecipients: cc.map(addr),
    });

    // Attach files from note actions (skip failures rather than failing
    // the whole send).
    for (const action of note.actions ?? []) {
      if (action.type === ActionType.file) {
        try {
          const file = await this.tools.files.read(action.fileId);
          if (file.data.length <= DIRECT_ATTACH_MAX_BYTES) {
            await api.addFileAttachment(draft.id, {
              name: file.fileName,
              contentType: file.mimeType,
              contentBytes: uint8ToBase64(file.data),
            });
          } else {
            await api.uploadLargeAttachment(draft.id, {
              name: file.fileName,
              contentType: file.mimeType,
              data: file.data,
            });
          }
        } catch (err) {
          console.error(
            `[outlook-mail] onNoteCreated: failed to attach file ${action.fileId}:`,
            err
          );
        }
      }
    }

    // Read the draft's internetMessageId before sending — it's the note key
    // sync-in will use for the sent message's echo.
    const refreshed = await api.getMessage(
      draft.id,
      "id,internetMessageId,conversationId"
    );
    const key =
      refreshed?.internetMessageId ?? draft.internetMessageId ?? draft.id;

    await api.send(draft.id);

    await this.set(sendGuardKey, { key });
    await this.set(`sent:${key}`, true);

    // No `externalContent`: Graph's send returns 202 with no stored body,
    // and the sent message is echo-suppressed above; the first sync-in
    // establishes the baseline naturally (same tradeoff as Gmail).
    return { key };
  }

  /**
   * Creates a new outbound email from Plot. The runtime fills
   * `draft.recipients` from connection-scoped rows (falling back to
   * `contact.email`); free-form typed addresses arrive via
   * `draft.inviteEmails`. Recipients split into To/Cc/Bcc by role so BCC
   * recipients never appear in visible headers.
   */
  override async onCreateLink(
    draft: CreateLinkDraft
  ): Promise<NewLinkWithNotes | null> {
    if (draft.type !== "email") return null;

    const seenEmails = new Set<string>();
    const toEmails: string[] = [];
    const ccEmails: string[] = [];
    const bccEmails: string[] = [];
    const addRecipient = (
      raw: string | null | undefined,
      role: string | null
    ) => {
      if (!raw) return;
      const trimmed = raw.trim();
      if (!trimmed) return;
      const key = trimmed.toLowerCase();
      if (seenEmails.has(key)) return;
      seenEmails.add(key);
      if (role === "cc") ccEmails.push(trimmed);
      else if (role === "bcc") bccEmails.push(trimmed);
      else toEmails.push(trimmed);
    };

    for (const r of draft.recipients ?? []) {
      addRecipient(r.externalAccountId, r.role);
    }
    for (const email of draft.inviteEmails ?? []) addRecipient(email, null);

    if (toEmails.length + ccEmails.length + bccEmails.length === 0) {
      console.error(
        "[outlook-mail] onCreateLink: no email recipients could be derived from draft"
      );
      return null;
    }

    const api = await this.getApiAny();
    if (!api) {
      console.error(
        "[outlook-mail] onCreateLink: no enabled channel to source auth from"
      );
      return null;
    }

    const fromEmail = await this.ensureUserEmail(api);
    const subject = draft.title || "";
    const body = draft.noteContent ?? "";

    // channelId: use the first enabled channel so onNoteCreated (reply path)
    // can resolve the OAuth token via getApi(channelId).
    const enabledChannels = await this.getEnabledChannels();
    const channelId = [...enabledChannels][0] ?? "";

    // Build the link the runtime wires to the originating thread. Shared
    // between the normal send and the dedup-hit path so a retried dispatch
    // returns an identical link.
    const linkFor = (conversationId: string): NewLinkWithNotes => ({
      source: conversationSource(fromEmail, conversationId),
      type: "email",
      title: subject || undefined,
      status: null,
      created: new Date(),
      sourceUrl: null,
      channelId,
      meta: {
        syncProvider: "microsoft",
        syncableId: channelId,
        channelId,
        conversationId,
      },
    });

    // Idempotency: dedupe on a content hash within the retry window.
    const dedupKey = `compose:${fnv1aHex(
      JSON.stringify([
        draft.type,
        subject,
        body,
        [...toEmails].sort(),
        [...ccEmails].sort(),
        [...bccEmails].sort(),
      ])
    )}`;
    const prior = await this.get<{ conversationId: string; at: number }>(
      dedupKey
    );
    if (
      prior?.conversationId &&
      Date.now() - prior.at < COMPOSE_DEDUP_WINDOW_MS
    ) {
      console.log(
        `[outlook-mail] onCreateLink: duplicate compose dispatch within ${COMPOSE_DEDUP_WINDOW_MS}ms, reusing conversation ${prior.conversationId}`
      );
      return linkFor(prior.conversationId);
    }

    const addr = (address: string) => ({ emailAddress: { address } });
    const created = await api.createDraft({
      subject,
      body: { contentType: "text", content: body },
      toRecipients: toEmails.map(addr),
      ccRecipients: ccEmails.map(addr),
      bccRecipients: bccEmails.map(addr),
    });

    // POST /me/messages returns the full draft; fall back to a re-fetch if
    // internetMessageId / conversationId are somehow absent.
    let imid = created.internetMessageId;
    let conversationId = created.conversationId;
    if (!imid || !conversationId) {
      const refreshed = await api.getMessage(
        created.id,
        "id,internetMessageId,conversationId"
      );
      imid = imid ?? refreshed?.internetMessageId;
      conversationId = conversationId ?? refreshed?.conversationId;
    }

    await api.send(created.id);

    if (!conversationId) {
      console.error(
        "[outlook-mail] onCreateLink: sent draft has no conversationId"
      );
      return null;
    }

    await this.set(dedupKey, { conversationId, at: Date.now() });

    // Suppress the echo when the sent message arrives via notification.
    const noteKey = imid ?? created.id;
    await this.set(`sent:${noteKey}`, true);

    return { ...linkFor(conversationId), originatingNote: { key: noteKey } };
  }

  /**
   * Downloads an attachment identified by the opaque `ref` emitted during
   * inbound sync. Ref format is `${graphMessageId}:${attachmentId}` (Graph
   * ImmutableIds are URL-safe base64 and never contain a colon).
   */
  override async downloadAttachment(ref: string): Promise<
    | { redirectUrl: string }
    | { body: Uint8Array; mimeType: string; fileName?: string }
  > {
    const colon = ref.indexOf(":");
    if (colon < 0) {
      throw new Error(`Invalid Outlook attachment ref: ${ref}`);
    }
    const messageId = ref.slice(0, colon);
    const attachmentId = ref.slice(colon + 1);

    // All channels share one mailbox, so any enabled channel's token works.
    const api = await this.getApiAny();
    if (!api) {
      throw new Error(
        "No enabled Outlook Mail channel to source auth from. " +
          "Try refreshing the Outlook Mail connection."
      );
    }

    const att = await api.getAttachment(messageId, attachmentId);
    if (!att?.contentBytes) {
      throw new Error(
        `Outlook attachment ${attachmentId} on message ${messageId} has no downloadable content`
      );
    }

    const binary = atob(att.contentBytes);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) {
      bytes[i] = binary.charCodeAt(i);
    }

    return {
      body: bytes,
      mimeType: att.contentType ?? "application/octet-stream",
      fileName: att.name,
    };
  }
}

export default OutlookMail;
