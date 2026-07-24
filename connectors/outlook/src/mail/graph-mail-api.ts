import { ActionType } from "@plotday/twister/plot";
import type {
  Action,
  NameTier,
  NewActor,
  NewContact,
  NewLinkWithNotes,
} from "@plotday/twister/plot";
import { isNoReplySender } from "@plotday/email-classifier";
import { stripQuotedReply } from "./email-parsing";

export type GraphRecipient = {
  emailAddress?: { name?: string; address?: string };
};

export type GraphHeader = { name: string; value: string };

/**
 * Microsoft Graph message resource (the fields we $select).
 * https://learn.microsoft.com/en-us/graph/api/resources/message
 */
export type GraphMessage = {
  id: string;
  conversationId?: string;
  internetMessageId?: string;
  subject?: string;
  bodyPreview?: string;
  body?: { contentType: "text" | "html"; content?: string };
  from?: GraphRecipient;
  toRecipients?: GraphRecipient[];
  ccRecipients?: GraphRecipient[];
  replyTo?: GraphRecipient[];
  receivedDateTime?: string;
  sentDateTime?: string;
  isRead?: boolean;
  isDraft?: boolean;
  flag?: { flagStatus?: "notFlagged" | "complete" | "flagged" };
  importance?: string;
  inferenceClassification?: "focused" | "other";
  parentFolderId?: string;
  hasAttachments?: boolean;
  webLink?: string;
  internetMessageHeaders?: GraphHeader[];
  "@odata.type"?: string;
  meetingMessageType?: string;
  event?: { iCalUId?: string };
};

export type GraphMailFolder = {
  id: string;
  displayName: string;
  parentFolderId?: string;
  totalItemCount?: number;
  isHidden?: boolean;
};

export type GraphAttachmentMeta = {
  id: string;
  name: string;
  contentType: string | null;
  size: number | null;
  isInline: boolean;
  /** "#microsoft.graph.fileAttachment" | itemAttachment | referenceAttachment */
  odataType: string;
};

/** Well-known folder name → folder id map (only the ones we care about). */
export type WellKnownFolders = Partial<
  Record<
    | "inbox"
    | "sentitems"
    | "archive"
    | "junkemail"
    | "deleteditems"
    | "drafts"
    | "outbox"
    | "conversationhistory",
    string
  >
>;

const WELL_KNOWN_NAMES = [
  "inbox",
  "sentitems",
  "archive",
  "junkemail",
  "deleteditems",
  "drafts",
  "outbox",
  "conversationhistory",
] as const;

/** Folders that are never offered as channels and never synced. */
export const EXCLUDED_WELL_KNOWN = [
  "junkemail",
  "deleteditems",
  "drafts",
  "outbox",
  "conversationhistory",
] as const;

export class GraphMailApiError extends Error {
  constructor(
    public status: number,
    public statusText: string,
    body: string
  ) {
    super(`Graph API error: ${status} ${statusText} - ${body}`);
    this.name = "GraphMailApiError";
  }
}

/** OData string-literal quoting: single quotes double inside '...'. */
export function odataQuote(value: string): string {
  return `'${value.replace(/'/g, "''")}'`;
}

const GRAPH = "https://graph.microsoft.com/v1.0";

const MESSAGE_SELECT_FIELDS = [
  "id",
  "conversationId",
  "internetMessageId",
  "subject",
  "bodyPreview",
  "body",
  "from",
  "toRecipients",
  "ccRecipients",
  "replyTo",
  "receivedDateTime",
  "sentDateTime",
  "isRead",
  "isDraft",
  "flag",
  "importance",
  "inferenceClassification",
  "parentFolderId",
  "hasAttachments",
  "webLink",
] as const;

/**
 * $select used wherever full message content is needed.
 * internetMessageHeaders is intentionally absent — Graph only reliably
 * returns it on single-message GETs, so facets fetch it separately
 * (getInternetMessageHeaders).
 *
 * meetingMessageType lives on the eventMessage subtype, not the base
 * `message` type. A single-item GET (getMessage) resolves the entity's
 * concrete runtime type, so referencing it bare here is fine — only
 * polymorphic *collection* queries need the OData cast (see
 * MESSAGE_SELECT_COLLECTION below). (There is no `meetingRequestType` in
 * Graph — that's an Exchange Web Services concept, not Graph's; Graph only
 * exposes `meetingMessageType`.)
 */
export const MESSAGE_SELECT = [
  ...MESSAGE_SELECT_FIELDS,
  "meetingMessageType",
].join(",");

/**
 * $select for the polymorphic /messages *collection* endpoints
 * (getMessagesPage, getConversationMessages). Graph requires an OData
 * type-cast for eventMessage-only properties here — and once any cast
 * segment appears in the query (the $expand for `event` needs one too),
 * Graph validates the whole request strictly and rejects a bare
 * meetingMessageType with "Could not find a property... on type
 * 'Microsoft.OutlookServices.Message'". Casting both eventMessage-only
 * references consistently (this + the $expand) is what Microsoft's own
 * docs specify for querying eventMessage fields on a collection:
 * https://learn.microsoft.com/en-us/graph/api/resources/eventmessage
 */
const MESSAGE_SELECT_COLLECTION = [
  ...MESSAGE_SELECT_FIELDS,
  "microsoft.graph.eventMessage/meetingMessageType",
].join(",");

/** Upload-session chunk size: 10 × 320 KiB (Graph requires 320 KiB multiples). */
const UPLOAD_CHUNK_BYTES = 3_276_800;

export class GraphMailApi {
  constructor(public accessToken: string) {}

  /**
   * Generic Graph call. Sends Prefer: ImmutableId (stable message ids across
   * folder moves — attachment refs and the msg-channel cache depend on it)
   * plus html body-content. Returns null on 404 (deleted upstream). Retries
   * once on 429/503 honoring Retry-After (capped 15s).
   */
  public async call(
    method: string,
    url: string,
    params?: Record<string, string>,
    body?: unknown,
    extraHeaders?: Record<string, string>
  ): Promise<any> {
    const query = params ? `?${new URLSearchParams(params)}` : "";
    const headers: Record<string, string> = {
      Authorization: `Bearer ${this.accessToken}`,
      Accept: "application/json",
      Prefer: `IdType="ImmutableId", outlook.body-content-type="html"`,
      ...(body !== undefined ? { "Content-Type": "application/json" } : {}),
      ...extraHeaders,
    };
    for (let attempt = 0; ; attempt++) {
      const response = await fetch(url + query, {
        method,
        headers,
        ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
      });
      if (response.status === 404) return null;
      if ((response.status === 429 || response.status === 503) && attempt === 0) {
        const retryAfter = Number(response.headers.get("Retry-After") ?? "2");
        await new Promise((r) =>
          setTimeout(r, Math.min(isNaN(retryAfter) ? 2 : retryAfter, 15) * 1000)
        );
        continue;
      }
      if (!response.ok) {
        throw new GraphMailApiError(
          response.status,
          response.statusText,
          await response.text()
        );
      }
      if (response.status === 202 || response.status === 204) return {};
      const text = await response.text();
      return text ? JSON.parse(text) : {};
    }
  }

  async getProfile(): Promise<{ email: string }> {
    const data = (await this.call("GET", `${GRAPH}/me`)) as {
      mail?: string;
      userPrincipalName?: string;
    } | null;
    return {
      email: (data?.mail || data?.userPrincipalName || "").toLowerCase(),
    };
  }

  /** All top-level mail folders, paged. */
  async getMailFolders(): Promise<GraphMailFolder[]> {
    const folders: GraphMailFolder[] = [];
    let url: string | null = `${GRAPH}/me/mailFolders`;
    let params: Record<string, string> | undefined = { $top: "100" };
    while (url) {
      const data: any = await this.call("GET", url, params);
      folders.push(...((data?.value as GraphMailFolder[] | undefined) ?? []));
      url = (data?.["@odata.nextLink"] as string | undefined) ?? null;
      params = undefined; // nextLink already carries the query
    }
    return folders;
  }

  /**
   * Resolve well-known folder ids by GETting /me/mailFolders/{name} per name.
   * 404s (e.g. no `archive` on some consumer accounts) are tolerated.
   *
   * Each name is an independent Graph call, so they're fired concurrently —
   * this runs during the synchronous connect-time getChannels() call, and 8
   * serial round-trips there risked exceeding the connect path's execution
   * budget (see connectors/AGENTS.md "Connect / enable-path performance
   * contract").
   */
  async getWellKnownFolderIds(): Promise<WellKnownFolders> {
    const entries = await Promise.all(
      WELL_KNOWN_NAMES.map(async (name) => {
        const data = (await this.call(
          "GET",
          `${GRAPH}/me/mailFolders/${name}`,
          { $select: "id" }
        )) as { id?: string } | null;
        return [name, data?.id] as const;
      })
    );
    const result: WellKnownFolders = {};
    for (const [name, id] of entries) {
      if (id) result[name] = id;
    }
    return result;
  }

  /** One newest-first page of a folder's messages (or follow a nextLink). */
  async getMessagesPage(args: {
    folderId?: string;
    nextLink?: string;
    top?: number;
    since?: Date;
  }): Promise<{ messages: GraphMessage[]; nextLink: string | null }> {
    let data: any;
    if (args.nextLink) {
      data = await this.call("GET", args.nextLink);
    } else {
      const params: Record<string, string> = {
        $top: String(args.top ?? 20),
        $orderby: "receivedDateTime desc",
        $select: MESSAGE_SELECT_COLLECTION,
        // `event` lives on the eventMessage subtype, not the base `message`
        // type this polymorphic /messages collection returns — Graph rejects
        // a bare `event(...)` expand with "Could not find a property named
        // 'event' on type 'microsoft.graph.message'". The OData type-cast
        // segment scopes the expand to items that are actually eventMessages;
        // plain messages just come back without an `event` field.
        $expand: "microsoft.graph.eventMessage/event($select=iCalUId)",
      };
      if (args.since) {
        params.$filter = `receivedDateTime ge ${args.since.toISOString()}`;
      }
      data = await this.call(
        "GET",
        `${GRAPH}/me/mailFolders/${encodeURIComponent(args.folderId!)}/messages`,
        params
      );
    }
    return {
      messages: (data?.value as GraphMessage[] | undefined) ?? [],
      nextLink: (data?.["@odata.nextLink"] as string | undefined) ?? null,
    };
  }

  async getMessage(
    id: string,
    select: string = MESSAGE_SELECT
  ): Promise<GraphMessage | null> {
    const data = await this.call(
      "GET",
      `${GRAPH}/me/messages/${encodeURIComponent(id)}`,
      { $select: select }
    );
    return (data as GraphMessage | null) ?? null;
  }

  /**
   * All messages in a conversation, oldest first. Graph rejects $orderby
   * combined with this $filter (InefficientFilter), so sorting is
   * client-side. Follows nextLinks up to 5 pages (500 messages).
   */
  async getConversationMessages(
    conversationId: string
  ): Promise<GraphMessage[]> {
    const messages: GraphMessage[] = [];
    let data: any = await this.call("GET", `${GRAPH}/me/messages`, {
      $filter: `conversationId eq ${odataQuote(conversationId)}`,
      $top: "100",
      $select: MESSAGE_SELECT_COLLECTION,
      $expand: "microsoft.graph.eventMessage/event($select=iCalUId)",
    });
    for (let page = 0; page < 5; page++) {
      messages.push(...((data?.value as GraphMessage[] | undefined) ?? []));
      const nextLink = data?.["@odata.nextLink"] as string | undefined;
      if (!nextLink) break;
      data = await this.call("GET", nextLink);
    }
    return sortConversation(messages);
  }

  async getInternetMessageHeaders(
    messageId: string
  ): Promise<GraphHeader[] | null> {
    const data = (await this.call(
      "GET",
      `${GRAPH}/me/messages/${encodeURIComponent(messageId)}`,
      { $select: "internetMessageHeaders" }
    )) as { internetMessageHeaders?: GraphHeader[] } | null;
    return data?.internetMessageHeaders ?? null;
  }

  async listAttachments(messageId: string): Promise<GraphAttachmentMeta[]> {
    const data = (await this.call(
      "GET",
      `${GRAPH}/me/messages/${encodeURIComponent(messageId)}/attachments`,
      { $select: "id,name,contentType,size,isInline" }
    )) as { value?: Array<Record<string, unknown>> } | null;
    return ((data?.value ?? []) as Array<Record<string, unknown>>).map((a) => ({
      id: a.id as string,
      name: (a.name as string) ?? "attachment",
      contentType: (a.contentType as string | undefined) ?? null,
      size: (a.size as number | undefined) ?? null,
      isInline: (a.isInline as boolean | undefined) ?? false,
      odataType: (a["@odata.type"] as string | undefined) ?? "",
    }));
  }

  async getAttachment(
    messageId: string,
    attachmentId: string
  ): Promise<{
    contentBytes?: string;
    contentType?: string;
    name?: string;
  } | null> {
    return (await this.call(
      "GET",
      `${GRAPH}/me/messages/${encodeURIComponent(messageId)}/attachments/${encodeURIComponent(attachmentId)}`
    )) as { contentBytes?: string; contentType?: string; name?: string } | null;
  }

  /** PATCH /me/messages/{id} — isRead, flag, draft body/recipients, … */
  async updateMessage(
    id: string,
    patch: Record<string, unknown>
  ): Promise<void> {
    await this.call(
      "PATCH",
      `${GRAPH}/me/messages/${encodeURIComponent(id)}`,
      undefined,
      patch
    );
  }

  /** POST /me/messages — returns the full draft (id, conversationId, internetMessageId). */
  async createDraft(draft: Record<string, unknown>): Promise<GraphMessage> {
    return (await this.call(
      "POST",
      `${GRAPH}/me/messages`,
      undefined,
      draft
    )) as GraphMessage;
  }

  /**
   * POST /me/messages/{id}/createReply — server threads the reply
   * (In-Reply-To / References / subject) and returns the draft.
   */
  async createReplyDraft(messageId: string): Promise<GraphMessage> {
    return (await this.call(
      "POST",
      `${GRAPH}/me/messages/${encodeURIComponent(messageId)}/createReply`,
      undefined,
      {}
    )) as GraphMessage;
  }

  /** POST /me/messages/{id}/send — 202, no body. */
  async send(messageId: string): Promise<void> {
    await this.call(
      "POST",
      `${GRAPH}/me/messages/${encodeURIComponent(messageId)}/send`,
      undefined,
      {}
    );
  }

  /** Direct attachment upload (≤3 MB). contentBytes is standard base64. */
  async addFileAttachment(
    messageId: string,
    att: { name: string; contentType: string; contentBytes: string }
  ): Promise<void> {
    await this.call(
      "POST",
      `${GRAPH}/me/messages/${encodeURIComponent(messageId)}/attachments`,
      undefined,
      {
        "@odata.type": "#microsoft.graph.fileAttachment",
        name: att.name,
        contentType: att.contentType,
        contentBytes: att.contentBytes,
      }
    );
  }

  /** Upload-session attachment upload (>3 MB), chunked PUTs to the session URL. */
  async uploadLargeAttachment(
    messageId: string,
    att: { name: string; contentType: string; data: Uint8Array }
  ): Promise<void> {
    const session = (await this.call(
      "POST",
      `${GRAPH}/me/messages/${encodeURIComponent(messageId)}/attachments/createUploadSession`,
      undefined,
      {
        AttachmentItem: {
          attachmentType: "file",
          name: att.name,
          size: att.data.length,
          contentType: att.contentType,
        },
      }
    )) as { uploadUrl?: string } | null;
    const uploadUrl = session?.uploadUrl;
    if (!uploadUrl) {
      throw new Error("Graph createUploadSession returned no uploadUrl");
    }
    const total = att.data.length;
    for (let start = 0; start < total; start += UPLOAD_CHUNK_BYTES) {
      const end = Math.min(start + UPLOAD_CHUNK_BYTES, total);
      const chunk = att.data.subarray(start, end);
      // The session URL is pre-authorized — no Authorization header.
      const response = await fetch(uploadUrl, {
        method: "PUT",
        headers: {
          "Content-Length": String(chunk.length),
          "Content-Range": `bytes ${start}-${end - 1}/${total}`,
        },
        body: chunk as unknown as BodyInit,
      });
      if (!response.ok) {
        throw new GraphMailApiError(
          response.status,
          response.statusText,
          await response.text()
        );
      }
    }
  }

  /** Mailbox-wide change-notification subscription on /me/messages. */
  async createSubscription(args: {
    notificationUrl: string;
    clientState: string;
    expirationDateTime: Date;
  }): Promise<{ id: string; expirationDateTime: string }> {
    const data = (await this.call("POST", `${GRAPH}/subscriptions`, undefined, {
      changeType: "created,updated",
      notificationUrl: args.notificationUrl,
      resource: "/me/messages",
      expirationDateTime: args.expirationDateTime.toISOString(),
      clientState: args.clientState,
    })) as { id: string; expirationDateTime: string };
    return data;
  }

  async renewSubscription(
    id: string,
    expirationDateTime: Date
  ): Promise<void> {
    const data = await this.call(
      "PATCH",
      `${GRAPH}/subscriptions/${encodeURIComponent(id)}`,
      undefined,
      { expirationDateTime: expirationDateTime.toISOString() }
    );
    if (data === null) {
      // 404 — subscription is gone; caller falls back to recreate.
      throw new GraphMailApiError(404, "Not Found", "subscription not found");
    }
  }

  async deleteSubscription(id: string): Promise<void> {
    await this.call(
      "DELETE",
      `${GRAPH}/subscriptions/${encodeURIComponent(id)}`
    );
  }

  /** One page of a delta walk. 410 (expired token) propagates as GraphMailApiError. */
  async deltaPage(url: string): Promise<{
    messages: GraphMessage[];
    nextLink: string | null;
    deltaLink: string | null;
  }> {
    const data: any = await this.call("GET", url);
    return {
      messages: (data?.value as GraphMessage[] | undefined) ?? [],
      nextLink: (data?.["@odata.nextLink"] as string | undefined) ?? null,
      deltaLink: (data?.["@odata.deltaLink"] as string | undefined) ?? null,
    };
  }

  /**
   * Initial delta URL for a folder, filtered to `since` so the baseline walk
   * is cheap (history was already imported by the initial backfill).
   */
  buildInitialDeltaUrl(folderId: string, since: Date): string {
    const params = new URLSearchParams({
      $filter: `receivedDateTime ge ${since.toISOString()}`,
      $select: "id,conversationId,parentFolderId,isDraft",
    });
    return `${GRAPH}/me/mailFolders/${encodeURIComponent(folderId)}/messages/delta?${params}`;
  }
}

// Pure helpers -----------------------------------------------------------

/** Trimmed addresses from structured recipients (skips blanks). */
export function recipientEmails(
  recipients: GraphRecipient[] | undefined
): string[] {
  return (recipients ?? [])
    .map((r) => r.emailAddress?.address?.trim())
    .filter((a): a is string => !!a);
}

/**
 * Mailing-list "Name via List" display-name decoration — the only rewrite
 * signal available without per-message internetMessageHeaders. Suppress the
 * display name on the From contact when it fires (see gmail's
 * isFromAddressRewritten for the full rationale: the name describes the
 * original sender, not the rewritten From address).
 */
export function isViaRewrittenName(name: string | undefined): boolean {
  return !!name && /\svia\s/i.test(name);
}

function recipientToContact(
  r: GraphRecipient,
  suppressName = false,
  automated = false,
  // A To/Cc display name is whatever the SENDER typed for this person, not a
  // self-assertion. Callers building the From contact pass "self" explicitly.
  nameTier: NameTier = "third-party"
): NewContact | null {
  const address = r.emailAddress?.address?.trim();
  if (!address) return null;
  const name = suppressName ? undefined : r.emailAddress?.name || undefined;
  return {
    email: address,
    ...(name ? { name } : {}),
    nameTier,
    // Graph messages don't expose the counterparty's AAD object id, so key
    // contact_external_account on the lowercased address (same tradeoff and
    // rationale as gmail's parseEmailAddressesToContacts).
    source: { accountId: address.toLowerCase() },
    ...(automated ? { automated: true } : {}),
  };
}

export function isConversationUnread(messages: GraphMessage[]): boolean {
  return messages.some((m) => !m.isDraft && m.isRead === false);
}

export function isConversationFlagged(messages: GraphMessage[]): boolean {
  return messages.some(
    (m) => !m.isDraft && m.flag?.flagStatus === "flagged"
  );
}

/**
 * Canonical upsert key for a conversation. Mailbox-qualified because Graph
 * conversationIds are mailbox-local (same global-uniqueness rule as
 * outlook-calendar's calendar-qualified event sources).
 */
export function conversationSource(
  accountEmail: string,
  conversationId: string
): string {
  return `outlook-mail:${accountEmail.toLowerCase()}:${conversationId}`;
}

export function messageDate(m: GraphMessage): Date {
  return new Date(m.receivedDateTime ?? m.sentDateTime ?? Date.now());
}

/** Sort a conversation oldest-first. */
export function sortConversation(messages: GraphMessage[]): GraphMessage[] {
  return [...messages].sort(
    (a, b) => messageDate(a).getTime() - messageDate(b).getTime()
  );
}

/**
 * Classify an Outlook conversation's relationship to a calendar event for
 * bundling onto the event's Plot thread. Two signals: our own
 * `X-Plot-Event-UID` header on the parent's raw headers (a Plot-sent reply
 * chain — checked first, regardless of any message-derived signal), or a
 * message's Graph meeting-message metadata (update/cancellation).
 *
 * Graph's `meetingMessageType` doesn't distinguish a brand-new invite from
 * an update/reschedule to an existing meeting the way Exchange Web
 * Services' `MeetingRequestType` (fullUpdate/informationalUpdate/
 * newMeetingRequest) does — Graph has no equivalent property, so every
 * `meetingRequest` bundles onto its event's thread here, new invite or not.
 * RSVP responses (accept/decline/tentative) fall through and are skipped,
 * since they match neither branch below.
 */
export function classifyOutlookCalendar(
  messages: GraphMessage[],
  parentHeaders: GraphHeader[] | null
): { uid: string; kind: "reply" | "update" | "cancel" } | null {
  const hdr = (parentHeaders ?? []).find(
    (h) => h.name.toLowerCase() === "x-plot-event-uid"
  );
  if (hdr?.value) return { uid: hdr.value, kind: "reply" };
  for (const m of messages) {
    const uid = m.event?.iCalUId;
    if (!uid) continue;
    if (m.meetingMessageType === "meetingCancelled") return { uid, kind: "cancel" };
    if (m.meetingMessageType === "meetingRequest") return { uid, kind: "update" };
  }
  return null;
}

/**
 * Transforms an Outlook conversation into a NewLinkWithNotes. The subject
 * becomes the link title, and each non-draft message becomes a note keyed
 * on its internetMessageId (stable across folder moves, and identical for
 * the synced-back echo of mail sent from Plot).
 */
export function transformOutlookConversation(opts: {
  messages: GraphMessage[];
  attachmentsByMessageId: Map<string, GraphAttachmentMeta[]>;
  accountEmail: string;
}): NewLinkWithNotes {
  // channelId is unknown at this call site — the caller always sets the
  // real value right after (see "Inject channel ID" in sync.ts) before saving.
  const sorted = sortConversation(opts.messages).filter((m) => !m.isDraft);
  if (sorted.length === 0) {
    return { channelId: null, type: "email", title: "", notes: [] };
  }

  const parent = sorted[0];
  const conversationId = parent.conversationId;
  if (!conversationId) {
    return { channelId: null, type: "email", title: "", notes: [] };
  }
  const source = conversationSource(opts.accountEmail, conversationId);

  // Collect all unique participants across messages for thread-level access.
  const participantsByEmail = new Map<string, NewContact>();
  const addParticipant = (contact: NewContact | null) => {
    if (!contact?.email) return;
    const key = contact.email.toLowerCase();
    if (!participantsByEmail.has(key)) participantsByEmail.set(key, contact);
  };
  for (const message of sorted) {
    if (message.from) {
      addParticipant(
        recipientToContact(
          message.from,
          isViaRewrittenName(message.from.emailAddress?.name),
          isNoReplySender(message.from.emailAddress?.address ?? null),
          // The sender named themselves on their own message.
          "self"
        )
      );
    }
    for (const r of message.toRecipients ?? []) addParticipant(recipientToContact(r));
    for (const r of message.ccRecipients ?? []) addParticipant(recipientToContact(r));
  }

  const plotThread: NewLinkWithNotes = {
    channelId: null,
    source,
    type: "email",
    title: parent.subject || "Email",
    created: messageDate(parent),
    access: "private",
    accessContacts: [...participantsByEmail.values()],
    meta: { conversationId },
    sourceUrl: sorted[sorted.length - 1].webLink ?? null,
    preview: parent.bodyPreview || null,
    notes: [],
  };

  for (const message of sorted) {
    const fromAddress = message.from?.emailAddress?.address;
    if (!fromAddress) continue; // Skip messages without sender

    const suppressName = isViaRewrittenName(message.from?.emailAddress?.name);
    const senderName = suppressName
      ? undefined
      : message.from?.emailAddress?.name || undefined;
    const senderIsNoReply = isNoReplySender(
      message.from?.emailAddress?.address ?? null
    );

    const contentType: "text" | "html" =
      message.body?.contentType === "html" ? "html" : "text";
    const body = stripQuotedReply(message.body?.content ?? "", contentType);
    const content = body || message.bodyPreview || "";

    const actions: Action[] = (
      opts.attachmentsByMessageId.get(message.id) ?? []
    )
      .filter(
        (a) =>
          !a.isInline && a.odataType === "#microsoft.graph.fileAttachment"
      )
      .map((a) => ({
        type: ActionType.fileRef as ActionType.fileRef,
        ref: `${message.id}:${a.id}`,
        fileName: a.name,
        fileSize: a.size,
        mimeType: a.contentType ?? "application/octet-stream",
      }));

    const senderActor: NewActor = {
      email: fromAddress,
      name: senderName,
      // The sender named themselves on their own message.
      nameTier: "self",
      automated: senderIsNoReply,
    };
    const messageContacts: NewContact[] = [
      ...(message.from
        ? [
            recipientToContact(
              message.from,
              suppressName,
              senderIsNoReply,
              "self"
            ),
          ]
        : []),
      ...(message.toRecipients ?? []).map((r) => recipientToContact(r)),
      ...(message.ccRecipients ?? []).map((r) => recipientToContact(r)),
    ].filter((c): c is NewContact => c !== null);

    // Assigned to a const before push (same as gmail): note keys ride along
    // structurally even though they're not part of the base NewNote type.
    const note = {
      key: message.internetMessageId ?? message.id,
      author: senderActor,
      content,
      contentType,
      actions: actions.length > 0 ? actions : null,
      accessContacts: messageContacts,
      created: messageDate(message),
      checkForTasks: true,
    };
    plotThread.notes!.push(note);
  }

  // Credit the thread to its originator — the first message's sender — so the
  // thread is authored by the human who started it, not the connection.
  // We reuse the first note's author so DMARC name suppression carries
  // through. Without this the runtime defaults thread.author_id to the
  // connection's twist_instance (e.g. "Outlook (Plot)"), which then surfaces
  // as the author in notifications and the thread header.
  const originator = plotThread.notes![0]?.author;
  if (originator) plotThread.author = originator;

  return plotThread;
}
