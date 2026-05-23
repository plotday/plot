import type {
  UnipileAccount,
  UnipileAttendee,
  UnipileAttendeeList,
  UnipileChat,
  UnipileChatList,
  UnipileHostedAuthLink,
  UnipileInvitationList,
  UnipileMessage,
  UnipileMessageList,
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
