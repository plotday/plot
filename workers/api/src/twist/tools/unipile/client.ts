import type {
  UnipileAccount,
  UnipileAccountList,
  UnipileChat,
  UnipileChatList,
  UnipileChatStarted,
  UnipileHostedAuthLink,
  UnipileInvitationList,
  UnipileMessageList,
  UnipileRelationList,
  UnipileSendResult,
  UnipileUser,
  UnipileWebhook,
  UnipileWebhookList,
} from "./types";

/** Thrown on non-2xx Unipile responses. */
export class UnipileApiError extends Error {
  constructor(
    message: string,
    public status: number,
    public bodyText: string
  ) {
    super(message);
    this.name = "UnipileApiError";
  }
}

type Env = {
  UNIPILE_API_KEY: string;
  UNIPILE_WEBHOOK_SECRET: string;
};

/** Unipile v2 is a single global host — no per-workspace DSN. */
export const UNIPILE_BASE = "https://api.unipile.com";

/** Default page size for offset/limit-paginated v2 list endpoints. */
const PAGE = 100;

/**
 * Thin HTTP client for Unipile's REST API **v2**. This is the only file in the
 * codebase that knows Unipile's URL shape, header set, or API key — every
 * other caller works against Plot-shaped wrappers.
 *
 * v2 uses a single host (`https://api.unipile.com`) with a `/v2` prefix and
 * carries `account_id` in the path for messaging/users routes.
 */
export class UnipileClient {
  private readonly base: string;
  private readonly fetchImpl: typeof fetch;

  constructor(private readonly env: Env, fetchImpl?: typeof fetch) {
    this.base = UNIPILE_BASE;
    // `globalThis.fetch` must keep `globalThis` as its `this` — calling it as
    // `this.fetchImpl(...)` rebinds `this` to the client instance, which the
    // Workers runtime rejects with "Illegal invocation". Bind it explicitly.
    this.fetchImpl = fetchImpl ?? globalThis.fetch.bind(globalThis);
  }

  // ---------- Account lifecycle ----------

  /**
   * Create a hosted-auth link. v2: `POST /v2/auth/link`. Verified live — the v2
   * body differs from v1: `providers` is a LOWERCASE enum array, redirects
   * collapse to a single `redirect_uri`, and the wizard link comes back under
   * `link` (not `url`). Unipile appends `account_id` to `redirect_uri` on
   * completion; `failureRedirectUrl` has no v2 equivalent (failures land on the
   * same `redirect_uri` and authBridge handles the missing account_id).
   */
  async createHostedAuthLink(input: {
    providers: ("LINKEDIN" | "WHATSAPP" | "INSTAGRAM")[];
    name: string;
    successRedirectUrl: string;
    failureRedirectUrl: string;
    notifyUrl: string;
    expiresAt: Date;
  }): Promise<UnipileHostedAuthLink> {
    const resp = await this.post<{ object?: string; link?: string; url?: string }>(
      "/v2/auth/link",
      {
        type: "create",
        providers: input.providers.map((p) => p.toLowerCase()),
        expires_on: input.expiresAt.toISOString(),
        redirect_uri: input.successRedirectUrl,
        notify_url: input.notifyUrl,
        name: input.name,
      }
    );
    return { object: "HostedAuthURL", url: resp.link ?? resp.url ?? "" };
  }

  getAccount(accountId: string): Promise<UnipileAccount> {
    return this.get<UnipileAccount>(
      `/v2/accounts/${encodeURIComponent(accountId)}`
    );
  }

  async deleteAccount(accountId: string): Promise<void> {
    await this.request(`/v2/accounts/${encodeURIComponent(accountId)}`, {
      method: "DELETE",
    });
  }

  /**
   * List every account in the Unipile workspace. v2 lists are offset/limit
   * paginated and report `has_more`. Used by account-cleanup to find orphans.
   */
  async listAccounts(): Promise<UnipileAccount[]> {
    const out: UnipileAccount[] = [];
    let offset = 0;
    for (;;) {
      const page = await this.get<UnipileAccountList>(
        "/v2/accounts",
        offset === 0
          ? { limit: String(PAGE) }
          : { limit: String(PAGE), offset: String(offset) }
      );
      out.push(...page.data);
      if (!page.has_more || page.data.length === 0) break;
      offset += page.data.length;
    }
    return out;
  }

  // ---------- Webhooks ----------

  listWebhooks(): Promise<UnipileWebhookList> {
    return this.get<UnipileWebhookList>("/v2/webhooks/endpoints");
  }

  /**
   * Create a unified webhook endpoint. v2 has one endpoint per URL that
   * subscribes to many `trigger_events`. The response carries a per-endpoint
   * signing `secret` (wes_…) used to verify deliveries.
   */
  createWebhook(input: {
    name: string;
    url: string;
    triggerEvents: string[];
    headers?: { key: string; value: string }[];
  }): Promise<UnipileWebhook> {
    return this.post<UnipileWebhook>("/v2/webhooks/endpoints", {
      name: input.name,
      url: input.url,
      trigger_events: input.triggerEvents,
      ...(input.headers ? { headers: input.headers } : {}),
    });
  }

  async deleteWebhook(id: string): Promise<void> {
    await this.request(`/v2/webhooks/endpoints/${encodeURIComponent(id)}`, {
      method: "DELETE",
    });
  }

  // ---------- Chats / messages ----------

  listChats(input: {
    accountId: string;
    offset?: number;
    limit?: number;
    folder?: string | null;
  }): Promise<UnipileChatList> {
    return this.get<UnipileChatList>(
      `/v2/${encodeURIComponent(input.accountId)}/chats`,
      {
        ...(input.limit ? { limit: String(input.limit) } : {}),
        ...(input.offset ? { offset: String(input.offset) } : {}),
        ...(input.folder ? { folder: input.folder } : {}),
      }
    );
  }

  /**
   * List chats within a specific inbox. v2 LinkedIn requires this — the generic
   * `GET /v2/:acc/chats` returns 501 ("Use List inbox Chats endpoint for this
   * provider"). Inbox ids are constants (e.g. CLASSIC_PRIMARY, CLASSIC_INMAIL);
   * results are cursor-paginated (`next_cursor`).
   */
  listInboxChats(input: {
    accountId: string;
    inboxId: string;
    cursor?: string | null;
    limit?: number;
  }): Promise<{ data: UnipileChat[]; next_cursor?: string | null }> {
    return this.get<{ data: UnipileChat[]; next_cursor?: string | null }>(
      `/v2/${encodeURIComponent(input.accountId)}/inboxes/${encodeURIComponent(input.inboxId)}/chats`,
      {
        ...(input.limit ? { limit: String(input.limit) } : {}),
        ...(input.cursor ? { cursor: input.cursor } : {}),
      }
    );
  }

  /**
   * Resolve a provider identifier (username, public id, or phone) to a user.
   * v2: `GET /v2/:account_id/users/:identifier`.
   */
  getUser(input: {
    accountId: string;
    identifier: string;
  }): Promise<UnipileUser> {
    return this.get<UnipileUser>(
      `/v2/${encodeURIComponent(input.accountId)}/users/${encodeURIComponent(input.identifier)}`
    );
  }

  getChat(input: { accountId: string; chatId: string }): Promise<UnipileChat> {
    return this.get<UnipileChat>(
      `/v2/${encodeURIComponent(input.accountId)}/chats/${encodeURIComponent(input.chatId)}`
    );
  }

  listMessages(input: {
    accountId: string;
    chatId: string;
    offset?: number;
    limit?: number;
  }): Promise<UnipileMessageList> {
    return this.get<UnipileMessageList>(
      `/v2/${encodeURIComponent(input.accountId)}/chats/${encodeURIComponent(input.chatId)}/messages`,
      {
        ...(input.limit ? { limit: String(input.limit) } : {}),
        ...(input.offset ? { offset: String(input.offset) } : {}),
      }
    );
  }

  /** Send a text message. v2 echoes `{ object: "MessageSent", message_id }`. */
  sendMessage(input: {
    accountId: string;
    chatId: string;
    text: string;
  }): Promise<UnipileSendResult> {
    return this.post<UnipileSendResult>(
      `/v2/${encodeURIComponent(input.accountId)}/chats/${encodeURIComponent(input.chatId)}/messages/send`,
      { text: input.text }
    );
  }

  /**
   * Send a message with file attachments. v2 takes base64 JSON attachments
   * (`{ filename, content_type, data }`), not multipart. Echoes `MessageSent`.
   */
  async sendMessageMultipart(input: {
    accountId: string;
    chatId: string;
    text: string;
    attachments: Array<{
      buffer: Uint8Array;
      filename: string;
      mimeType: string;
    }>;
  }): Promise<UnipileSendResult> {
    const attachments = input.attachments.map((a) => ({
      filename: a.filename,
      content_type: a.mimeType,
      data: base64FromBytes(a.buffer),
    }));
    return this.post<UnipileSendResult>(
      `/v2/${encodeURIComponent(input.accountId)}/chats/${encodeURIComponent(input.chatId)}/messages/send`,
      { text: input.text, attachments }
    );
  }

  /**
   * Download an attachment by message + attachment id.
   * LIVE-CONFIRM: exact v2 attachment path (account-scoped here).
   */
  async downloadAttachmentRaw(input: {
    accountId: string;
    messageId: string;
    attachmentId: string;
  }): Promise<Response> {
    const url = `${this.base}/v2/${encodeURIComponent(input.accountId)}/messages/${encodeURIComponent(input.messageId)}/attachments/${encodeURIComponent(input.attachmentId)}`;
    const response = await this.fetchImpl(url, {
      method: "GET",
      headers: { "X-API-KEY": this.env.UNIPILE_API_KEY, accept: "*/*" },
    });
    if (!response.ok) {
      const text = await response.text().catch(() => "");
      throw new UnipileApiError(
        `Unipile GET attachment returned ${response.status}`,
        response.status,
        text
      );
    }
    return response;
  }

  /**
   * Start a new chat (1:1 or group) and send the first message.
   * v2: `POST /v2/:account_id/chats/send` with `users_ids` (renamed from
   * `attendees_ids`) and base64 attachments.
   */
  async startChat(input: {
    accountId: string;
    attendeeProviderIds: string[];
    text: string;
    title?: string | null;
  }): Promise<UnipileChatStarted> {
    return this.post<UnipileChatStarted>(
      `/v2/${encodeURIComponent(input.accountId)}/chats/send`,
      {
        users_ids: input.attendeeProviderIds,
        text: input.text,
        ...(input.title ? { name: input.title } : {}),
      }
    );
  }

  /**
   * Add (or replace) the connected account's reaction on a message.
   * v2: `POST /v2/:account_id/chats/:chat_id/messages/:message_id/reactions`
   * with body `{ reaction }` (confirmed live: route is plural, field is
   * `reaction`, and chat_id is required in the path).
   */
  async addMessageReaction(input: {
    accountId: string;
    chatId: string;
    messageId: string;
    reaction: string;
  }): Promise<void> {
    await this.post<unknown>(this.reactionPath(input), {
      reaction: input.reaction,
    });
  }

  /**
   * Remove the connected account's reaction from a message. Confirmed live:
   * an empty `{ reaction: "" }` POST clears it. The DELETE fallback + swallowed
   * 400/404/405 stay as defense so an unsupported clear never breaks write-back.
   */
  async removeMessageReaction(input: {
    accountId: string;
    chatId: string;
    messageId: string;
  }): Promise<void> {
    const path = this.reactionPath(input);
    try {
      await this.post<unknown>(path, { reaction: "" });
      return;
    } catch (e) {
      if (
        !(e instanceof UnipileApiError) ||
        (e.status !== 400 && e.status !== 404 && e.status !== 405)
      )
        throw e;
    }
    try {
      await this.request(path, { method: "DELETE" });
    } catch (e) {
      if (
        e instanceof UnipileApiError &&
        (e.status === 404 || e.status === 405)
      )
        return;
      throw e;
    }
  }

  private reactionPath(input: {
    accountId: string;
    chatId: string;
    messageId: string;
  }): string {
    return `/v2/${encodeURIComponent(input.accountId)}/chats/${encodeURIComponent(input.chatId)}/messages/${encodeURIComponent(input.messageId)}/reactions`;
  }

  async setChatRequestStatus(input: {
    accountId: string;
    chatId: string;
    accepted: boolean;
  }): Promise<void> {
    // LIVE-CONFIRM: IG accept/ignore message-request action on PATCH chat.
    await this.request(
      `/v2/${encodeURIComponent(input.accountId)}/chats/${encodeURIComponent(input.chatId)}`,
      {
        method: "PATCH",
        body: JSON.stringify({
          action: input.accepted ? "acceptRequest" : "declineRequest",
        }),
        headers: { "content-type": "application/json" },
      }
    );
  }

  async setChatRead(input: {
    accountId: string;
    chatId: string;
    read: boolean;
  }): Promise<void> {
    await this.request(
      `/v2/${encodeURIComponent(input.accountId)}/chats/${encodeURIComponent(input.chatId)}`,
      {
        method: "PATCH",
        body: JSON.stringify({
          action: input.read ? "setReadStatus" : "setUnreadStatus",
          value: input.read,
        }),
        headers: { "content-type": "application/json" },
      }
    );
  }

  /** Fetch the connected account's own provider profile. */
  getOwnProfile(input: { accountId: string }): Promise<UnipileUser> {
    return this.get<UnipileUser>(
      `/v2/${encodeURIComponent(input.accountId)}/users/me`
    );
  }

  // ---------- LinkedIn invitations / relations ----------

  /**
   * Received connection invitations.
   * v2: `GET /v2/:acc/users/me/relation-requests?type=received` (cursor-paged).
   * (The bare `/users/invitations` path v1 used is parsed by v2 as
   * `users/:user_id`, so it must be the `me`-scoped relation-requests route.)
   */
  listReceivedInvitations(input: {
    accountId: string;
    cursor?: string | null;
    limit?: number;
  }): Promise<UnipileInvitationList> {
    return this.get<UnipileInvitationList>(
      `/v2/${encodeURIComponent(input.accountId)}/users/me/relation-requests`,
      {
        type: "received",
        ...(input.limit ? { limit: String(input.limit) } : {}),
        ...(input.cursor ? { cursor: input.cursor } : {}),
      }
    );
  }

  /**
   * 1st-degree connections.
   * v2: `GET /v2/:acc/users/me/relations` (cursor-paged). The bare
   * `/users/relations` path v1 used is parsed by v2 as `users/:user_id`.
   */
  listRelations(input: {
    accountId: string;
    cursor?: string | null;
    limit?: number;
  }): Promise<UnipileRelationList> {
    return this.get<UnipileRelationList>(
      `/v2/${encodeURIComponent(input.accountId)}/users/me/relations`,
      {
        ...(input.limit ? { limit: String(input.limit) } : {}),
        ...(input.cursor ? { cursor: input.cursor } : {}),
      }
    );
  }

  /**
   * Accept a received connection invitation.
   * v2: `POST /v2/:acc/users/me/relation-requests/:id/accept` (confirmed live;
   * no shared_secret — the request id is sufficient).
   */
  async acceptInvitation(input: {
    accountId: string;
    invitationId: string;
  }): Promise<void> {
    await this.request(
      `/v2/${encodeURIComponent(input.accountId)}/users/me/relation-requests/${encodeURIComponent(input.invitationId)}/accept`,
      { method: "POST", body: "{}", headers: { "content-type": "application/json" } }
    );
  }

  /**
   * Ignore (decline) a received connection invitation.
   * v2: `POST /v2/:acc/users/me/relation-requests/:id/cancel` (confirmed live).
   */
  async ignoreInvitation(input: {
    accountId: string;
    invitationId: string;
  }): Promise<void> {
    await this.request(
      `/v2/${encodeURIComponent(input.accountId)}/users/me/relation-requests/${encodeURIComponent(input.invitationId)}/cancel`,
      { method: "POST", body: "{}", headers: { "content-type": "application/json" } }
    );
  }

  getAttendee(input: {
    accountId: string;
    providerId: string;
  }): Promise<UnipileUser> {
    return this.get<UnipileUser>(
      `/v2/${encodeURIComponent(input.accountId)}/users/${encodeURIComponent(input.providerId)}`
    );
  }

  // ---------- Internals ----------

  private get<T>(path: string, query?: Record<string, string>): Promise<T> {
    const qs =
      query && Object.keys(query).length > 0
        ? "?" + new URLSearchParams(query).toString()
        : "";
    return this.request<T>(`${path}${qs}`, { method: "GET" });
  }

  private post<T>(path: string, body: unknown): Promise<T> {
    return this.request<T>(path, {
      method: "POST",
      body: JSON.stringify(body),
      headers: { "content-type": "application/json" },
    });
  }

  private async request<T>(path: string, init: RequestInit, attempt = 0): Promise<T> {
    const url = `${this.base}${path}`;
    const headers = {
      "X-API-KEY": this.env.UNIPILE_API_KEY,
      accept: "application/json",
      ...((init.headers as Record<string, string>) ?? {}),
    };
    const response = await this.fetchImpl(url, { ...init, headers });

    // Rate limit: LinkedIn (and other providers) throttle hard, especially
    // during a backfill. Respect `Retry-After` (seconds) when present, else back
    // off exponentially, capped — then retry a few times before giving up so a
    // transient 429 doesn't fail the whole sync.
    if (response.status === 429 && attempt < MAX_429_RETRIES) {
      const retryAfter = Number(response.headers.get("retry-after"));
      const delaySec = Math.min(
        Number.isFinite(retryAfter) && retryAfter > 0 ? retryAfter : 2 ** attempt,
        RETRY_CAP_SECONDS
      );
      await new Promise((resolve) => setTimeout(resolve, delaySec * 1000));
      return this.request<T>(path, init, attempt + 1);
    }

    if (!response.ok) {
      const text = await response.text().catch(() => "");
      throw new UnipileApiError(
        `Unipile ${init.method} ${path} returned ${response.status}`,
        response.status,
        text
      );
    }
    if (response.status === 204) return undefined as T;
    return (await response.json()) as T;
  }
}

/** 429 retry policy. Kept small so a backfill page doesn't block too long; the
 * queue retry handles sustained throttling. */
const MAX_429_RETRIES = 3;
const RETRY_CAP_SECONDS = 8;

/** Base64-encode bytes for v2 JSON attachment uploads (Workers-safe). */
function base64FromBytes(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]!);
  return btoa(binary);
}
