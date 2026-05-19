import type { Kysely } from "kysely";

import type {
  LinkedIn as ILinkedIn,
  LinkedInAttachment,
  LinkedInConversation,
  LinkedInConversationPage,
  LinkedInInvitation,
  LinkedInInvitationPage,
  LinkedInMessage,
  LinkedInMessagePage,
  LinkedInProfile,
} from "@plotday/twister/tools/linkedin";

import type { DB } from "../../db-types";
import { type Bindings } from "../../env";
import { type StoredTokenData, type LinkedInProviderData } from "../../provider";
import { createLogger } from "@plotday/worker-util";
import { Store } from "./store";
import { Tool } from "./tool";
import {
  type VoyagerCredentials,
  VoyagerAuthError,
  voyagerFetch,
} from "./linkedin-voyager";

/**
 * Built-in `LinkedIn` tool — concrete implementation.
 *
 * The connector calls clean methods like `listConversations` and the wire
 * format (Voyager endpoints, header set, response normalization), rate
 * limiting, and the per-channel cookie/User-Agent pinning all live here.
 * Open-source connector code never sees the raw cookie.
 *
 * Storage layout (in the shared sibling-Storage DO):
 *   `auth_token:linkedin:<actorId>` → `StoredTokenData` (LinkedInProviderData)
 *   `channel_config:linkedin:<channelId>` → `{ enabled, enabledBy, title }`
 *
 * Rate limiting: `env.LINKEDIN_RATE_LIMITER` (6 reqs / 10s) keyed by
 * channelId. When the bucket is empty the call short-throttles (sleep then
 * retry) so the connector never has to think about pacing.
 */
export class LinkedIn extends Tool implements ILinkedIn {
  /**
   * Store handle that resolves to the SAME DurableObject as the sibling
   * Integrations tool's store. `Store.path.slice(0, -1)` is what drives
   * the DO id, so an Integrations tool at path `[…, "Integrations"]` and
   * a LinkedIn tool at path `[…, "LinkedIn"]` both name into
   * `${twistInstanceId}:${parentPath}` and share state.
   *
   * Critical: must use `Store`, not raw `STORAGE.get(...)`. Integrations
   * writes via `Store.set` which serializes with superjson — a `JSON.parse`
   * of the raw bytes returns the `{json, meta}` superjson envelope, not the
   * value, and any field read off it is `undefined`.
   */
  private store: Store;

  constructor(
    private options: {
      env: Bindings;
      db: Kysely<DB>;
      twistInstanceId: string;
      path: string[];
    }
  ) {
    super();
    this.store = new Store({
      path: options.path,
      storage: options.env.STORAGE,
      twistInstanceId: options.twistInstanceId,
    });
  }

  // ---------------------------------------------------------------------------
  // Public surface — see the abstract class in twister for method docs.
  // ---------------------------------------------------------------------------

  async listConversations(params: {
    channelId: string;
    cursor?: string | null;
    limit?: number;
    since?: Date;
  }): Promise<LinkedInConversationPage> {
    const { creds } = await this.contextFor(params.channelId);
    const limit = params.limit ?? 20;

    const query: Record<string, string> = {
      q: "syncToken",
      count: String(limit),
    };
    if (params.cursor) query.lastUpdatedBefore = params.cursor;

    const raw = await this.callVoyager(params.channelId, creds, () =>
      voyagerFetch(creds, "/voyagerMessagingDashMailbox/messengerConversations", {
        query,
      })
    );

    return normalizeConversationPage(raw, params.since);
  }

  async getConversation(params: {
    channelId: string;
    conversationUrn: string;
  }): Promise<LinkedInConversation> {
    const { creds } = await this.contextFor(params.channelId);
    const raw = await this.callVoyager(params.channelId, creds, () =>
      voyagerFetch(
        creds,
        `/voyagerMessagingDashMessengerConversations/${encodeURIComponent(
          params.conversationUrn
        )}`
      )
    );
    const conv = normalizeConversation(raw, raw);
    if (!conv) {
      throw new Error(
        `LinkedIn conversation not found: ${params.conversationUrn}`
      );
    }
    return conv;
  }

  async getMessages(params: {
    channelId: string;
    conversationUrn: string;
    cursor?: string | null;
    limit?: number;
    since?: Date;
  }): Promise<LinkedInMessagePage> {
    const { creds, profileUrn } = await this.contextFor(params.channelId);
    const limit = params.limit ?? 20;

    const query: Record<string, string> = {
      q: "messages",
      conversationUrn: params.conversationUrn,
      count: String(limit),
    };
    if (params.cursor) query.deliveredAt = params.cursor;

    const raw = await this.callVoyager(params.channelId, creds, () =>
      voyagerFetch(creds, "/voyagerMessagingDashMessengerMessages", { query })
    );

    return normalizeMessagePage(raw, profileUrn, params.since);
  }

  async sendMessage(params: {
    channelId: string;
    conversationUrn: string;
    text: string;
  }): Promise<LinkedInMessage> {
    const { creds, profileUrn } = await this.contextFor(params.channelId);

    // Voyager's "create message" endpoint posts a JSON body that describes
    // both the conversation reference and the message text. Keep the
    // payload minimal — we do not attach mentions or attributes here.
    const body = JSON.stringify({
      message: {
        body: {
          attributes: [],
          text: params.text,
        },
        renderContentUnions: [],
        conversationUrn: params.conversationUrn,
        originToken: crypto.randomUUID(),
      },
    });

    const raw = await this.callVoyager(params.channelId, creds, () =>
      voyagerFetch(
        creds,
        `/voyagerMessagingDashMessengerMessages?action=createMessage`,
        { method: "POST", body }
      )
    );

    const message = normalizeSingleMessage(raw, profileUrn);
    if (!message) {
      throw new Error("LinkedIn did not return a sent-message envelope");
    }
    return message;
  }

  async markConversationRead(params: {
    channelId: string;
    conversationUrn: string;
    read: boolean;
  }): Promise<void> {
    const { creds } = await this.contextFor(params.channelId);

    // Patch the conversation's `read` flag. The Voyager partial-update
    // wire format is `{ patch: { $set: { ... } } }`.
    const body = JSON.stringify({
      patch: { $set: { read: params.read } },
    });

    await this.callVoyager(params.channelId, creds, () =>
      voyagerFetch(
        creds,
        `/voyagerMessagingDashMessengerConversations/${encodeURIComponent(
          params.conversationUrn
        )}`,
        { method: "POST", body }
      )
    );
  }

  async listConnectionInvitations(params: {
    channelId: string;
    cursor?: string | null;
    limit?: number;
  }): Promise<LinkedInInvitationPage> {
    const { creds } = await this.contextFor(params.channelId);
    const limit = params.limit ?? 20;

    const query: Record<string, string> = {
      q: "receivedInvitation",
      count: String(limit),
    };
    if (params.cursor) query.start = params.cursor;

    const raw = await this.callVoyager(params.channelId, creds, () =>
      voyagerFetch(creds, "/relationships/invitationViews", { query })
    );

    return normalizeInvitationPage(raw);
  }

  async acceptInvitation(params: {
    channelId: string;
    invitationUrn: string;
    sharedSecret: string;
  }): Promise<void> {
    const { creds } = await this.contextFor(params.channelId);
    const id = lastUrnSegment(params.invitationUrn);
    const body = JSON.stringify({ sharedSecret: params.sharedSecret });
    await this.callVoyager(params.channelId, creds, () =>
      voyagerFetch(
        creds,
        `/relationships/invitations/${id}?action=accept`,
        { method: "POST", body }
      )
    );
  }

  async ignoreInvitation(params: {
    channelId: string;
    invitationUrn: string;
    sharedSecret: string;
  }): Promise<void> {
    const { creds } = await this.contextFor(params.channelId);
    const id = lastUrnSegment(params.invitationUrn);
    const body = JSON.stringify({ sharedSecret: params.sharedSecret });
    await this.callVoyager(params.channelId, creds, () =>
      voyagerFetch(
        creds,
        `/relationships/invitations/${id}?action=ignore`,
        { method: "POST", body }
      )
    );
  }

  async getProfile(params: {
    channelId: string;
    profileUrn: string;
  }): Promise<LinkedInProfile> {
    const { creds } = await this.contextFor(params.channelId);
    const raw = await this.callVoyager(params.channelId, creds, () =>
      voyagerFetch(
        creds,
        `/identity/dash/profiles/${encodeURIComponent(params.profileUrn)}`
      )
    );
    const profile = normalizeProfile(raw);
    if (!profile) {
      throw new Error(`LinkedIn profile not found: ${params.profileUrn}`);
    }
    return profile;
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  /**
   * Resolve the active credentials for a channel.
   *
   * Reads channel_config to find `enabledBy` (the actor who turned on the
   * channel), then reads that actor's stored LinkedIn token. Throws if
   * either is missing or the token has no LinkedInProviderData attached —
   * these conditions indicate the connector tried to call us before the
   * cookie was captured or after the connection was disabled.
   */
  private async contextFor(channelId: string): Promise<{
    creds: VoyagerCredentials;
    actorId: string;
    profileUrn: string;
  }> {
    const channelConfigKey = `channel_config:linkedin:${channelId}`;
    const channelConfig = await this.store.get<{
      enabled?: boolean;
      enabledBy?: string;
      title?: string | null;
    }>(channelConfigKey);
    if (!channelConfig?.enabledBy) {
      throw new Error(
        `LinkedIn channel ${channelId} is not enabled by any actor`
      );
    }

    const tokenKey = `auth_token:linkedin:${channelConfig.enabledBy}`;
    const token = await this.store.get<StoredTokenData>(tokenKey);
    if (!token?.access_token || !token.providerData) {
      throw new Error(
        `LinkedIn channel ${channelId} has no usable stored token (enabledBy=${channelConfig.enabledBy})`
      );
    }

    const providerData = token.providerData as LinkedInProviderData;
    if (!providerData.jsessionid || !providerData.userAgent) {
      throw new Error(
        `LinkedIn channel ${channelId} token is missing jsessionid/userAgent — reconnect`
      );
    }

    return {
      creds: {
        liAt: token.access_token,
        jsessionid: providerData.jsessionid,
        userAgent: providerData.userAgent,
      },
      actorId: channelConfig.enabledBy,
      profileUrn: providerData.userId,
    };
  }

  /**
   * Wrap a Voyager call with rate limiting and auth-error handling.
   *
   * If the per-channel bucket is empty we sleep briefly and try again
   * (LinkedIn rate-limit caps are roughly aligned with the bucket window).
   * On `VoyagerAuthError` we flag the connection for re-auth and re-throw
   * so the connector's caller can short-circuit.
   */
  private async callVoyager<T>(
    channelId: string,
    _creds: VoyagerCredentials,
    fn: () => Promise<T>
  ): Promise<T> {
    const limiter = this.options.env.LINKEDIN_RATE_LIMITER;
    // Best-effort throttle — bucket runs at 6 reqs / 10s per channel. If
    // we're past the bucket, wait ~1500ms and try once more before giving
    // up. The connector treats throwing here as a transient error.
    for (let attempt = 0; attempt < 2; attempt++) {
      const decision = await limiter.limit({ key: channelId });
      if (decision.success) break;
      if (attempt === 0) {
        await sleep(1500);
        continue;
      }
      throw new Error(`LinkedIn rate limit exceeded for channel ${channelId}`);
    }

    try {
      return await fn();
    } catch (error) {
      if (error instanceof VoyagerAuthError) {
        await this.flagReauth(channelId);
      }
      throw error;
    }
  }

  /**
   * Mirror Integrations.markNeedsReauth's behavior on the
   * `twist_instance_connection` row so the Flutter app's re-auth prompt
   * surfaces immediately.
   */
  private async flagReauth(channelId: string): Promise<void> {
    const logger = createLogger({
      twist_instance_id: this.options.twistInstanceId,
    });
    try {
      const channelConfigKey = `channel_config:linkedin:${channelId}`;
      const channelConfig = await this.store.get<{ enabledBy?: string }>(
        channelConfigKey
      );
      if (!channelConfig?.enabledBy) return;

      const reauthContact = await this.options.db
        .selectFrom("contact")
        .select("user_id")
        .where("id", "=", channelConfig.enabledBy)
        .executeTakeFirst();
      if (!reauthContact?.user_id) return;

      const now = new Date().toISOString();
      await this.options.db
        .insertInto("twist_instance_connection")
        .values({
          twist_instance_id: this.options.twistInstanceId,
          user_id: reauthContact.user_id,
          provider: "linkedin",
          actor_id: channelConfig.enabledBy,
          connected_at: now,
          needs_reauth_at: now,
          recovery_pending: true,
        })
        .onConflict((oc) =>
          oc
            .columns(["twist_instance_id", "user_id", "provider"])
            .doUpdateSet({ needs_reauth_at: now, recovery_pending: true })
            .where("twist_instance_connection.needs_reauth_at", "is", null)
        )
        .execute();
    } catch (dbError) {
      logger.warn(
        `Failed to flag LinkedIn reauth for channel ${channelId}: ${(dbError as Error)?.message ?? String(dbError)}`,
        { channel_id: channelId }
      );
    }
  }

}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function lastUrnSegment(urn: string): string {
  const idx = urn.lastIndexOf(":");
  return idx >= 0 ? urn.slice(idx + 1) : urn;
}

// ---------------------------------------------------------------------------
// Response normalization
// ---------------------------------------------------------------------------
//
// Voyager returns Restli-style envelopes:
//   { data: { elements: [...] }, included: [...] }
// where the elements reference URNs that are expanded in `included`. We
// resolve those references here so the connector receives flat, Plot-shaped
// objects. The shapes have evolved across LinkedIn releases, so each
// normalizer tolerates missing/renamed fields rather than throwing.

type VoyagerEnvelope = {
  data?: any;
  included?: any[];
};

function asEnvelope(raw: unknown): VoyagerEnvelope {
  if (!raw || typeof raw !== "object") return {};
  return raw as VoyagerEnvelope;
}

function buildIncludedMap(included: any[] | undefined): Map<string, any> {
  const map = new Map<string, any>();
  for (const entry of included ?? []) {
    const urn: string | undefined = entry?.entityUrn ?? entry?.dashEntityUrn;
    if (urn) map.set(urn, entry);
  }
  return map;
}

function normalizeConversationPage(
  raw: unknown,
  since?: Date
): LinkedInConversationPage {
  const env = asEnvelope(raw);
  const included = buildIncludedMap(env.included);
  const elements = (env.data?.elements as any[] | undefined) ?? [];

  const conversations: LinkedInConversation[] = [];
  let nextCursor: string | null = null;

  for (const element of elements) {
    const conv = normalizeConversation(element, included);
    if (!conv) continue;
    if (since && conv.lastActivityAt < since) continue;
    conversations.push(conv);
    const ts = conv.lastActivityAt.getTime();
    if (!nextCursor || ts < Number(nextCursor)) nextCursor = String(ts);
  }

  return {
    conversations,
    nextCursor: conversations.length < elements.length ? nextCursor : nextCursor,
  };
}

function normalizeConversation(
  element: any,
  includedSource: Map<string, any> | any
): LinkedInConversation | null {
  if (!element) return null;
  const included =
    includedSource instanceof Map
      ? includedSource
      : buildIncludedMap(asEnvelope(includedSource).included);

  const urn: string | undefined = element.entityUrn ?? element.dashEntityUrn;
  if (!urn) return null;

  const lastActivityMs: number =
    Number(element.lastActivityAt) ||
    Number(element.lastUpdatedAt) ||
    Date.now();

  const participantUrns: string[] = (element.conversationParticipants ?? element.participants ?? [])
    .map((p: any) => p?.entityUrn ?? p?.["*hostIdentityUrn"] ?? p)
    .filter((u: any) => typeof u === "string");

  const participants = participantUrns
    .map((u) => normalizeProfile(included.get(u)))
    .filter((p): p is LinkedInProfile => p != null);

  const lastMessage = resolveLastMessage(element, included);

  return {
    urn,
    title: element.title ?? element.groupChatName ?? null,
    isGroup: participantUrns.length > 1,
    participants,
    lastMessagePreview: lastMessage?.text ?? null,
    lastActivityAt: new Date(lastActivityMs),
    unreadCount: Number(element.unreadCount ?? 0) || 0,
    archived: Boolean(element.archived ?? false),
    url: `https://www.linkedin.com/messaging/thread/${lastUrnSegment(urn)}/`,
  };
}

function resolveLastMessage(
  conv: any,
  included: Map<string, any>
): { text: string } | null {
  const ref = conv.lastMessage ?? conv["*lastMessage"];
  if (typeof ref === "string") {
    const msg = included.get(ref);
    if (msg) return extractMessageText(msg);
  } else if (ref && typeof ref === "object") {
    return extractMessageText(ref);
  }
  return null;
}

function extractMessageText(msg: any): { text: string } | null {
  if (!msg) return null;
  const text: string =
    msg.body?.text ?? msg.subtitle ?? msg.previewText ?? "";
  return { text };
}

function normalizeMessagePage(
  raw: unknown,
  profileUrn: string,
  since?: Date
): LinkedInMessagePage {
  const env = asEnvelope(raw);
  const included = buildIncludedMap(env.included);
  const elements = (env.data?.elements as any[] | undefined) ?? [];

  const messages: LinkedInMessage[] = [];
  let nextCursor: string | null = null;

  for (const element of elements) {
    const msg = normalizeMessage(element, included, profileUrn);
    if (!msg) continue;
    if (since && msg.sentAt < since) continue;
    messages.push(msg);
    const ts = msg.sentAt.getTime();
    if (!nextCursor || ts < Number(nextCursor)) nextCursor = String(ts);
  }

  return { messages, nextCursor };
}

function normalizeSingleMessage(
  raw: unknown,
  profileUrn: string
): LinkedInMessage | null {
  const env = asEnvelope(raw);
  const included = buildIncludedMap(env.included);
  // Some endpoints return the created message under `data.value`, others
  // under `data` directly. Try both.
  const value = env.data?.value ?? env.data;
  return normalizeMessage(value, included, profileUrn);
}

function normalizeMessage(
  element: any,
  included: Map<string, any>,
  profileUrn: string
): LinkedInMessage | null {
  if (!element) return null;
  const urn: string | undefined = element.entityUrn ?? element.backendUrn;
  if (!urn) return null;

  const conversationUrn: string =
    element.conversation?.entityUrn ??
    element["*conversation"] ??
    element.conversationUrn ??
    "";

  const senderUrn: string =
    element.sender?.entityUrn ??
    element["*sender"] ??
    element.from?.entityUrn ??
    "";

  const sentAtMs: number =
    Number(element.deliveredAt) || Number(element.createdAt) || Date.now();

  const text: string = element.body?.text ?? "";
  const html: string | null = element.body?.attributes?.length
    ? renderAttributedText(text, element.body.attributes as any[])
    : null;

  const attachments: LinkedInAttachment[] = (element.attachments ?? [])
    .map((a: any) => normalizeAttachment(a, included))
    .filter((a: LinkedInAttachment | null): a is LinkedInAttachment => a != null);

  return {
    urn,
    conversationUrn,
    senderUrn,
    sentByMe: senderUrn === profileUrn,
    sentAt: new Date(sentAtMs),
    text,
    html,
    attachments,
  };
}

function renderAttributedText(text: string, attrs: any[]): string {
  // Voyager attribute markers reference offset/length ranges in the raw
  // text and an `attributeKindUnion` describing the formatting (BOLD,
  // HYPERLINK, etc.). Rendering them all is out of scope here — we emit a
  // minimal HTML form that handles links and line breaks, which is what
  // server-side HTML→Markdown needs. Other attributes degrade to plain
  // text.
  let html = "";
  const sorted = [...attrs].sort((a, b) => (a.start ?? 0) - (b.start ?? 0));
  let cursor = 0;
  for (const attr of sorted) {
    const start = attr.start ?? 0;
    const len = attr.length ?? 0;
    if (start > cursor) html += escapeHtml(text.slice(cursor, start));
    const slice = text.slice(start, start + len);
    const link =
      attr.attributeKindUnion?.hyperlink?.url ??
      attr.type?.hyperlink?.url;
    if (link) {
      html += `<a href="${escapeHtml(link)}">${escapeHtml(slice)}</a>`;
    } else {
      html += escapeHtml(slice);
    }
    cursor = start + len;
  }
  if (cursor < text.length) html += escapeHtml(text.slice(cursor));
  return html.replace(/\n/g, "<br>");
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function normalizeAttachment(
  raw: any,
  _included: Map<string, any>
): LinkedInAttachment | null {
  if (!raw) return null;
  const urn: string = raw.entityUrn ?? raw.id ?? "";
  if (!urn) return null;

  let kind: LinkedInAttachment["kind"] = "other";
  const mediaType: string | undefined =
    raw.mediaType ?? raw.contentType ?? undefined;
  if (mediaType?.startsWith("image/")) kind = "image";
  else if (mediaType?.startsWith("video/")) kind = "video";
  else if (mediaType?.startsWith("audio/")) kind = "audio";
  else if (raw.name || raw.fileName) kind = "file";

  return {
    urn,
    kind,
    name: raw.name ?? raw.fileName ?? null,
    url: raw.reference?.url ?? raw.url ?? "",
    contentType: mediaType ?? null,
    byteSize: Number(raw.byteSize ?? raw.size ?? 0) || null,
  };
}

function normalizeProfile(raw: any): LinkedInProfile | null {
  if (!raw) return null;
  const urn: string | undefined = raw.entityUrn ?? raw.dashEntityUrn;
  if (!urn) return null;

  const firstName: string = raw.firstName ?? raw.firstNameLocalized ?? "";
  const lastName: string = raw.lastName ?? raw.lastNameLocalized ?? "";
  const fullName = `${firstName} ${lastName}`.trim() || raw.publicIdentifier || "Unknown";

  const pictureRoot: string | undefined =
    raw.picture?.rootUrl ??
    raw.profilePicture?.displayImageReference?.vectorImage?.rootUrl;
  const pictureArtifact: string | undefined =
    raw.picture?.artifacts?.[raw.picture.artifacts.length - 1]
      ?.fileIdentifyingUrlPathSegment ??
    raw.profilePicture?.displayImageReference?.vectorImage?.artifacts?.[
      (raw.profilePicture.displayImageReference.vectorImage.artifacts?.length ??
        0) - 1
    ]?.fileIdentifyingUrlPathSegment;

  const pictureUrl =
    pictureRoot && pictureArtifact ? pictureRoot + pictureArtifact : null;

  const publicIdentifier: string | null = raw.publicIdentifier ?? null;

  return {
    urn,
    publicIdentifier,
    fullName,
    headline: raw.headline ?? raw.occupation ?? null,
    email: raw.emailAddress ?? null,
    pictureUrl,
    url: publicIdentifier
      ? `https://www.linkedin.com/in/${publicIdentifier}`
      : null,
  };
}

function normalizeInvitationPage(raw: unknown): LinkedInInvitationPage {
  const env = asEnvelope(raw);
  const included = buildIncludedMap(env.included);
  const elements = (env.data?.elements as any[] | undefined) ?? [];

  const invitations: LinkedInInvitation[] = [];
  let lastIdx = 0;
  for (const [idx, element] of elements.entries()) {
    const inv = normalizeInvitation(element, included);
    if (!inv) continue;
    invitations.push(inv);
    lastIdx = idx + 1;
  }

  return {
    invitations,
    nextCursor: invitations.length > 0 ? String(lastIdx) : null,
  };
}

function normalizeInvitation(
  element: any,
  included: Map<string, any>
): LinkedInInvitation | null {
  if (!element) return null;
  const invitation = element.invitation ?? element;
  const urn: string | undefined = invitation.entityUrn ?? invitation.invitationId;
  if (!urn) return null;

  const inviterRef: string | undefined =
    invitation.fromMemberProfile?.["*entityUrn"] ??
    invitation.fromMember?.["*entityUrn"] ??
    invitation["*fromMemberProfile"];
  const inviterRaw = inviterRef ? included.get(inviterRef) : invitation.fromMember;
  const inviter = normalizeProfile(inviterRaw);
  if (!inviter) return null;

  const sentMs: number = Number(invitation.sentTime) || Date.now();

  return {
    urn,
    sharedSecret: invitation.sharedSecret ?? "",
    inviter,
    message: invitation.message?.text ?? invitation.customMessage ?? null,
    sentAt: new Date(sentMs),
  };
}
