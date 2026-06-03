import type {
  UnipileAccount,
  UnipileAccountList,
  UnipileAttendee,
  UnipileAttendeeList,
  UnipileChat,
  UnipileChatList,
  UnipileHostedAuthLink,
  UnipileInvitationList,
  UnipileMessage,
  UnipileMessageList,
  UnipileRelationList,
  UnipileWebhook,
  UnipileWebhookSource,
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
  UNIPILE_DSN: string;
  UNIPILE_WEBHOOK_SECRET: string;
};

/**
 * Thin HTTP client for Unipile's REST API. This is the only file in the
 * codebase that knows Unipile's URL shape, header set, or API key — every
 * other caller works against Plot-shaped wrappers.
 *
 * The DSN selects the region (`api6`, `api7`, …); Unipile assigns one per
 * workspace.
 */
export class UnipileClient {
  private readonly base: string;

  constructor(private readonly env: Env) {
    // Unipile assigns a per-workspace DSN as a full `host:port`
    // (e.g. `api40.unipile.com:17020`). Use it verbatim.
    this.base = `https://${env.UNIPILE_DSN}/api/v1`;
  }

  // ---------- Account lifecycle ----------

  async createHostedAuthLink(input: {
    providers: ("LINKEDIN" | "WHATSAPP" | "INSTAGRAM")[];
    name: string;
    successRedirectUrl: string;
    failureRedirectUrl: string;
    notifyUrl: string;
    expiresAt: Date;
  }): Promise<UnipileHostedAuthLink> {
    return this.post<UnipileHostedAuthLink>("/hosted/accounts/link", {
      type: "create",
      providers: input.providers,
      api_url: this.base,
      expiresOn: input.expiresAt.toISOString(),
      name: input.name,
      success_redirect_url: input.successRedirectUrl,
      failure_redirect_url: input.failureRedirectUrl,
      notify_url: input.notifyUrl,
    });
  }

  getAccount(accountId: string): Promise<UnipileAccount> {
    return this.get<UnipileAccount>(
      `/accounts/${encodeURIComponent(accountId)}`
    );
  }

  async deleteAccount(accountId: string): Promise<void> {
    await this.request(`/accounts/${encodeURIComponent(accountId)}`, {
      method: "DELETE",
    });
  }

  /**
   * List every account in the Unipile workspace. The workspace holds at most a
   * handful of accounts, but the endpoint is cursor-paginated so we walk all
   * pages. Used by account-cleanup to find orphaned accounts to delete.
   */
  async listAccounts(): Promise<UnipileAccount[]> {
    const out: UnipileAccount[] = [];
    let cursor: string | null = null;
    do {
      const page: UnipileAccountList = await this.get<UnipileAccountList>(
        "/accounts",
        cursor ? { cursor } : undefined
      );
      out.push(...page.items);
      cursor = page.cursor ?? null;
    } while (cursor);
    return out;
  }

  // ---------- Webhooks ----------

  /**
   * Webhook `source` selects which event family fires:
   *   - `messaging`       → messaging.new_message (and the rest of the chat events)
   *   - `account_status`  → account.connected / .disconnected / .error / .credentials
   *   - `users`           → users.invitation.received (LinkedIn connection requests)
   */
  listWebhooks(): Promise<{
    object: "WebhookList";
    items: UnipileWebhook[];
  }> {
    return this.get<{ object: "WebhookList"; items: UnipileWebhook[] }>(
      "/webhooks"
    );
  }

  createWebhook(input: {
    source: UnipileWebhookSource;
    requestUrl: string;
    /** Custom request headers Unipile attaches to every delivery. The
     * workspace bootstrap uses this to carry a shared token the receiver
     * verifies (Unipile itself does not sign payloads). */
    headers?: { key: string; value: string }[];
    /** Optional event filter; omitted = all events for the source. */
    events?: string[];
  }): Promise<UnipileWebhook> {
    return this.post<UnipileWebhook>("/webhooks", {
      source: input.source,
      request_url: input.requestUrl,
      ...(input.headers ? { headers: input.headers } : {}),
      ...(input.events ? { events: input.events } : {}),
    });
  }

  async deleteWebhook(id: string): Promise<void> {
    await this.request(`/webhooks/${encodeURIComponent(id)}`, {
      method: "DELETE",
    });
  }

  // ---------- Chats / messages ----------

  listChats(input: {
    accountId: string;
    cursor?: string | null;
    limit?: number;
  }): Promise<UnipileChatList> {
    return this.get<UnipileChatList>("/chats", {
      account_id: input.accountId,
      ...(input.cursor ? { cursor: input.cursor } : {}),
      ...(input.limit ? { limit: String(input.limit) } : {}),
    });
  }

  getChat(input: { chatId: string }): Promise<UnipileChat> {
    return this.get<UnipileChat>(
      `/chats/${encodeURIComponent(input.chatId)}`
    );
  }

  listChatAttendees(input: { chatId: string }): Promise<UnipileAttendeeList> {
    return this.get<UnipileAttendeeList>(
      `/chats/${encodeURIComponent(input.chatId)}/attendees`
    );
  }

  listMessages(input: {
    chatId: string;
    cursor?: string | null;
    limit?: number;
  }): Promise<UnipileMessageList> {
    return this.get<UnipileMessageList>(
      `/chats/${encodeURIComponent(input.chatId)}/messages`,
      {
        ...(input.cursor ? { cursor: input.cursor } : {}),
        ...(input.limit ? { limit: String(input.limit) } : {}),
      }
    );
  }

  sendMessage(input: { chatId: string; text: string }): Promise<UnipileMessage> {
    return this.post<UnipileMessage>(
      `/chats/${encodeURIComponent(input.chatId)}/messages`,
      { text: input.text }
    );
  }

  /**
   * Send a message with file attachments via multipart/form-data.
   * Used when the caller has one or more files to attach alongside the text.
   */
  async sendMessageMultipart(input: {
    chatId: string;
    text: string;
    attachments: Array<{ buffer: Uint8Array; filename: string; mimeType: string }>;
  }): Promise<UnipileMessage> {
    const form = new FormData();
    form.append("text", input.text);
    for (const att of input.attachments) {
      form.append(
        "files[]",
        new Blob([att.buffer], { type: att.mimeType }),
        att.filename
      );
    }
    return this.requestFormData<UnipileMessage>(
      `/chats/${encodeURIComponent(input.chatId)}/messages`,
      form
    );
  }

  /**
   * Download an attachment from a message by its Unipile attachment id.
   * Returns the raw Response so the caller can stream bytes or redirect.
   */
  async downloadAttachmentRaw(input: {
    messageId: string;
    attachmentId: string;
  }): Promise<Response> {
    const url = `${this.base}/messages/${encodeURIComponent(input.messageId)}/attachments/${encodeURIComponent(input.attachmentId)}`;
    const response = await fetch(url, {
      method: "GET",
      headers: {
        "X-API-KEY": this.env.UNIPILE_API_KEY,
        accept: "*/*",
      },
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
   * Start a new LinkedIn DM with one or more recipients and send the first
   * message. Unipile's `POST /messages` endpoint creates the chat if one
   * does not already exist; for 1:1 conversations it reuses the existing
   * thread.
   *
   * @param accountId - Unipile account id for the sender.
   * @param attendeeProviderIds - LinkedIn `provider_id` values for each
   *   recipient (the `provider_id` field on `UnipileAttendee`). Pass one for
   *   1:1, two or more for group.
   * @param text - Plain-text message body.
   */
  startChat(input: {
    accountId: string;
    attendeeProviderIds: string[];
    text: string;
  }): Promise<UnipileMessage> {
    // TODO: Endpoint and body shape are unverified against Unipile docs.
    // If the endpoint differs (e.g. POST /chats with a participants array, or a
    // LinkedIn-specific path), this will fail at runtime with a 404/422.
    // Requires a local end-to-end test against a real Unipile account before shipping.
    return this.post<UnipileMessage>("/messages", {
      account_id: input.accountId,
      attendees_ids: input.attendeeProviderIds,
      text: input.text,
    });
  }

  /**
   * Add (or replace) the connected account's reaction on a LinkedIn message.
   * LinkedIn DMs allow at most one reaction per member per message — posting
   * a new value replaces any prior reaction the account had on that message.
   *
   * Endpoint: `POST /messages/{id}/reactions` with body `{ reaction: "👍" }`.
   * See <https://developer.unipile.com/reference/messagescontroller_addreaction>.
   */
  async addMessageReaction(input: {
    messageId: string;
    reaction: string;
  }): Promise<void> {
    await this.post<unknown>(
      `/messages/${encodeURIComponent(input.messageId)}/reactions`,
      { reaction: input.reaction }
    );
  }

  /**
   * Remove the connected account's reaction from a LinkedIn message.
   * Unipile only documents the add endpoint; this attempts a `DELETE` on the
   * mirror path and treats `404`/`405` as "removal unsupported" so the
   * caller does not blow up. The next inbound sync of the message
   * reconciles state if Unipile silently rejects the call.
   */
  async removeMessageReaction(input: { messageId: string }): Promise<void> {
    try {
      await this.request(
        `/messages/${encodeURIComponent(input.messageId)}/reactions`,
        { method: "DELETE" }
      );
    } catch (error) {
      if (
        error instanceof UnipileApiError &&
        (error.status === 404 || error.status === 405)
      ) {
        // Unipile doesn't expose a removal endpoint for this provider.
        // The next sync of the message will reconcile actual state.
        return;
      }
      throw error;
    }
  }

  async setChatRead(input: { chatId: string; read: boolean }): Promise<void> {
    await this.request(`/chats/${encodeURIComponent(input.chatId)}`, {
      method: "PATCH",
      body: JSON.stringify({
        action: input.read ? "setReadStatus" : "setUnreadStatus",
        value: input.read,
      }),
      headers: { "content-type": "application/json" },
    });
  }

  /** Fetch the profile of the user the account belongs to (LinkedIn member,
   * WhatsApp number owner, etc.). Used at auth-completion time to populate
   * the connection's display name. */
  getOwnProfile(input: { accountId: string }): Promise<UnipileAttendee> {
    return this.get<UnipileAttendee>(`/users/me`, {
      account_id: input.accountId,
    });
  }

  // ---------- LinkedIn invitations ----------

  listReceivedInvitations(input: {
    accountId: string;
    cursor?: string | null;
    limit?: number;
  }): Promise<UnipileInvitationList> {
    return this.get<UnipileInvitationList>("/users/invite/received", {
      account_id: input.accountId,
      ...(input.cursor ? { cursor: input.cursor } : {}),
      ...(input.limit ? { limit: String(input.limit) } : {}),
    });
  }

  listRelations(input: {
    accountId: string;
    cursor?: string | null;
    limit?: number;
  }): Promise<UnipileRelationList> {
    return this.get<UnipileRelationList>("/users/relations", {
      account_id: input.accountId,
      ...(input.cursor ? { cursor: input.cursor } : {}),
      ...(input.limit ? { limit: String(input.limit) } : {}),
    });
  }

  async acceptInvitation(input: {
    invitationId: string;
    sharedSecret: string;
  }): Promise<void> {
    await this.request(
      `/users/invite/received/${encodeURIComponent(input.invitationId)}`,
      {
        method: "POST",
        body: JSON.stringify({
          action: "accept",
          shared_secret: input.sharedSecret,
        }),
        headers: { "content-type": "application/json" },
      }
    );
  }

  async ignoreInvitation(input: {
    invitationId: string;
    sharedSecret: string;
  }): Promise<void> {
    await this.request(
      `/users/invite/received/${encodeURIComponent(input.invitationId)}`,
      {
        method: "POST",
        body: JSON.stringify({
          action: "ignore",
          shared_secret: input.sharedSecret,
        }),
        headers: { "content-type": "application/json" },
      }
    );
  }

  getAttendee(input: { providerId: string }): Promise<UnipileAttendee> {
    return this.get<UnipileAttendee>(
      `/users/${encodeURIComponent(input.providerId)}`
    );
  }

  // ---------- Internals ----------

  private async requestFormData<T>(path: string, form: FormData): Promise<T> {
    const url = `${this.base}${path}`;
    const headers = {
      "X-API-KEY": this.env.UNIPILE_API_KEY,
      accept: "application/json",
      // Do NOT set content-type — browser/runtime sets it with the boundary
    };
    const response = await fetch(url, { method: "POST", body: form, headers });
    if (!response.ok) {
      const text = await response.text().catch(() => "");
      throw new UnipileApiError(
        `Unipile POST ${path} returned ${response.status}`,
        response.status,
        text
      );
    }
    return (await response.json()) as T;
  }

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

  private async request<T>(path: string, init: RequestInit): Promise<T> {
    const url = `${this.base}${path}`;
    const headers = {
      "X-API-KEY": this.env.UNIPILE_API_KEY,
      accept: "application/json",
      ...((init.headers as Record<string, string>) ?? {}),
    };
    const response = await fetch(url, { ...init, headers });
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
