import type {
  NewLinkWithNotes,
  NewActor,
} from "@plotday/twister/plot";
import { AuthProvider } from "@plotday/twister/tools/integrations";

// ---- Microsoft Graph API types ----

export type Team = {
  id: string;
  displayName: string;
  description?: string;
};

export type TeamsChannel = {
  id: string;
  displayName: string;
  description?: string;
  membershipType?: "standard" | "private" | "shared";
};

export type TeamsUser = {
  id: string;
  displayName?: string;
  mail?: string;
  userPrincipalName?: string;
};

export type TeamsMessageBody = {
  contentType: "text" | "html";
  content: string;
};

export type TeamsMessage = {
  id: string;
  createdDateTime: string;
  lastModifiedDateTime?: string;
  messageType: "message" | "systemEventMessage" | "unknownFutureValue";
  from?: {
    user?: TeamsUser;
    application?: { id: string; displayName?: string };
  };
  body: TeamsMessageBody;
  subject?: string | null;
  mentions?: Array<{
    id: number;
    mentionText: string;
    mentioned: {
      user?: TeamsUser;
    };
  }>;
  replies?: TeamsMessage[];
};

export type Chat = {
  id: string;
  topic?: string | null;
  chatType: "oneOnOne" | "group" | "meeting" | "unknownFutureValue";
  members?: ChatMember[];
};

export type ChatMember = {
  id: string;
  displayName?: string;
  email?: string;
  userId?: string;
};

export type Subscription = {
  id: string;
  resource: string;
  changeType: string;
  expirationDateTime: string;
  clientState?: string;
};

export type PaginatedResponse<T> = {
  value: T[];
  "@odata.nextLink"?: string;
};

export type SyncState = {
  channelId: string;
  cursor?: string;
  more?: boolean;
  oldest?: string;
  initialSync?: boolean;
};

// ---- Graph API Client ----

export class GraphApi {
  private baseUrl = "https://graph.microsoft.com/v1.0";

  constructor(public accessToken: string) {}

  private async call<T>(
    method: string,
    url: string,
    body?: unknown
  ): Promise<T | null> {
    const headers: Record<string, string> = {
      Authorization: `Bearer ${this.accessToken}`,
      Accept: "application/json",
      ...(body ? { "Content-Type": "application/json" } : {}),
    };

    const response = await fetch(url, {
      method,
      headers,
      ...(body ? { body: JSON.stringify(body) } : {}),
    });

    switch (response.status) {
      case 200:
      case 201:
        return (await response.json()) as T;
      case 204:
        return {} as T;
      case 400: {
        const err = await response.json();
        throw new Error("Invalid request", { cause: err });
      }
      case 401:
        throw new Error("Authentication failed - token may be expired");
      case 403:
        throw new Error("Access denied - insufficient permissions");
      case 404:
        return null;
      case 429:
        throw new Error("Rate limit exceeded - too many requests");
      default:
        if (response.status >= 500) {
          throw new Error(`Server error: ${response.status}`);
        }
        throw new Error(await response.text());
    }
  }

  // ---- User ----

  async getMe(): Promise<TeamsUser> {
    const data = await this.call<TeamsUser>("GET", `${this.baseUrl}/me`);
    if (!data) throw new Error("Failed to get user profile");
    return data;
  }

  // ---- Teams & Channels ----

  async getJoinedTeams(): Promise<Team[]> {
    const data = await this.call<PaginatedResponse<Team>>(
      "GET",
      `${this.baseUrl}/me/joinedTeams`
    );
    return data?.value ?? [];
  }

  async getChannels(teamId: string): Promise<TeamsChannel[]> {
    const data = await this.call<PaginatedResponse<TeamsChannel>>(
      "GET",
      `${this.baseUrl}/teams/${teamId}/channels`
    );
    return data?.value ?? [];
  }

  // ---- Channel Messages ----

  async getChannelMessages(
    teamId: string,
    channelId: string,
    params?: { top?: number; skipToken?: string }
  ): Promise<PaginatedResponse<TeamsMessage>> {
    let url = `${this.baseUrl}/teams/${teamId}/channels/${channelId}/messages?$top=${params?.top ?? 50}`;
    if (params?.skipToken) {
      url = params.skipToken; // skipToken is a full URL from @odata.nextLink
    }
    const data = await this.call<PaginatedResponse<TeamsMessage>>("GET", url);
    return data ?? { value: [] };
  }

  async getMessageReplies(
    teamId: string,
    channelId: string,
    messageId: string
  ): Promise<TeamsMessage[]> {
    const data = await this.call<PaginatedResponse<TeamsMessage>>(
      "GET",
      `${this.baseUrl}/teams/${teamId}/channels/${channelId}/messages/${messageId}/replies`
    );
    return data?.value ?? [];
  }

  async sendChannelReply(
    teamId: string,
    channelId: string,
    messageId: string,
    content: string
  ): Promise<TeamsMessage | null> {
    return this.call<TeamsMessage>(
      "POST",
      `${this.baseUrl}/teams/${teamId}/channels/${channelId}/messages/${messageId}/replies`,
      { body: { contentType: "html", content } }
    );
  }

  // ---- Chats (DMs) ----

  async getChats(): Promise<Chat[]> {
    const data = await this.call<PaginatedResponse<Chat>>(
      "GET",
      `${this.baseUrl}/me/chats?$filter=chatType eq 'oneOnOne' or chatType eq 'group'&$expand=members`
    );
    return data?.value ?? [];
  }

  async getChatMessages(
    chatId: string,
    params?: { top?: number; skipToken?: string }
  ): Promise<PaginatedResponse<TeamsMessage>> {
    let url = `${this.baseUrl}/chats/${chatId}/messages?$top=${params?.top ?? 50}`;
    if (params?.skipToken) {
      url = params.skipToken;
    }
    const data = await this.call<PaginatedResponse<TeamsMessage>>("GET", url);
    return data ?? { value: [] };
  }

  async sendChatMessage(
    chatId: string,
    content: string
  ): Promise<TeamsMessage | null> {
    return this.call<TeamsMessage>(
      "POST",
      `${this.baseUrl}/chats/${chatId}/messages`,
      { body: { contentType: "html", content } }
    );
  }

  async getChatMembers(chatId: string): Promise<ChatMember[]> {
    const data = await this.call<PaginatedResponse<ChatMember>>(
      "GET",
      `${this.baseUrl}/chats/${chatId}/members`
    );
    return data?.value ?? [];
  }

  // ---- Subscriptions ----

  async createSubscription(
    resource: string,
    notificationUrl: string,
    changeType: string,
    expirationMinutes: number
  ): Promise<Subscription> {
    const expirationDateTime = new Date(
      Date.now() + expirationMinutes * 60 * 1000
    );
    const data = await this.call<Subscription>(
      "POST",
      `${this.baseUrl}/subscriptions`,
      {
        changeType,
        notificationUrl,
        resource,
        expirationDateTime: expirationDateTime.toISOString(),
        clientState: crypto.randomUUID(),
      }
    );
    if (!data) throw new Error("Failed to create subscription");
    return data;
  }

  async renewSubscription(
    subscriptionId: string,
    expirationMinutes: number
  ): Promise<Subscription> {
    const expirationDateTime = new Date(
      Date.now() + expirationMinutes * 60 * 1000
    );
    const data = await this.call<Subscription>(
      "PATCH",
      `${this.baseUrl}/subscriptions/${subscriptionId}`,
      { expirationDateTime: expirationDateTime.toISOString() }
    );
    if (!data) throw new Error("Failed to renew subscription");
    return data;
  }

  async deleteSubscription(subscriptionId: string): Promise<void> {
    await this.call<void>(
      "DELETE",
      `${this.baseUrl}/subscriptions/${subscriptionId}`
    );
  }
}

// ---- Transform functions ----

/**
 * Converts a Teams user reference to a NewActor for Plot.
 * Uses Microsoft provider source for identity resolution.
 */
function userToNewActor(user?: TeamsUser): NewActor | undefined {
  if (!user) return undefined;
  return {
    name: user.displayName ?? user.id,
    email: user.mail ?? undefined,
    source: { provider: AuthProvider.Microsoft, accountId: user.id },
  };
}

/**
 * Extracts @mentions from a Teams message as NewActor[].
 */
function extractMentions(message: TeamsMessage): NewActor[] {
  if (!message.mentions) return [];
  return message.mentions
    .filter((m) => m.mentioned.user)
    .map((m) => ({
      name: m.mentionText,
      source: m.mentioned.user?.id
        ? { provider: AuthProvider.Microsoft, accountId: m.mentioned.user.id }
        : undefined,
    }));
}

/**
 * Strips HTML tags to produce a plain-text snippet for titles/previews.
 */
function stripHtml(html: string): string {
  return html
    .replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/\s+/g, " ")
    .trim();
}

/**
 * Transforms a Teams channel message thread (parent + replies) into a
 * NewLinkWithNotes structure for saving via integrations.saveLink().
 */
export function transformChannelThread(
  parentMessage: TeamsMessage,
  replies: TeamsMessage[],
  teamId: string,
  channelId: string,
  initialSync: boolean
): NewLinkWithNotes {
  const title =
    stripHtml(parentMessage.body.content).substring(0, 50) ||
    "Teams message";

  const allMessages = [parentMessage, ...replies];

  return {
    source: `ms-teams:channel:${channelId}:message:${parentMessage.id}`,
    type: "message",
    title,
    created: new Date(parentMessage.createdDateTime),
    author: userToNewActor(parentMessage.from?.user),
    preview: stripHtml(parentMessage.body.content) || null,
    meta: {
      teamId,
      channelId,
      messageId: parentMessage.id,
    },
    notes: allMessages
      .filter((msg) => msg.messageType === "message")
      .map((msg) => ({
        key: msg.id,
        author: userToNewActor(msg.from?.user),
        content: msg.body.content,
        contentType: msg.body.contentType === "html" ? ("html" as const) : ("text" as const),
        created: new Date(msg.createdDateTime),
        mentions: extractMentions(msg),
      })),
    ...(initialSync ? { unread: false, archived: false } : {}),
  };
}

/**
 * Transforms a Teams DM chat into a NewLinkWithNotes structure.
 * DMs are private threads with all participants as mentions for visibility.
 */
export function transformDmThread(
  messages: TeamsMessage[],
  chatId: string,
  members: NewActor[],
  initialSync: boolean
): NewLinkWithNotes {
  const firstMessage = messages[0];
  if (!firstMessage) {
    return {
      source: `ms-teams:dm:${chatId}`,
      type: "message",
      title: "Empty chat",
      private: true,
      notes: [],
    };
  }

  const title =
    stripHtml(firstMessage.body.content).substring(0, 50) || "Teams chat";

  return {
    source: `ms-teams:dm:${chatId}`,
    type: "message",
    title,
    private: true,
    created: new Date(firstMessage.createdDateTime),
    author: userToNewActor(firstMessage.from?.user),
    preview: stripHtml(firstMessage.body.content) || null,
    meta: {
      chatId,
    },
    notes: messages
      .filter((msg) => msg.messageType === "message")
      .map((msg) => ({
        key: msg.id,
        author: userToNewActor(msg.from?.user),
        content: msg.body.content,
        contentType: msg.body.contentType === "html" ? ("html" as const) : ("text" as const),
        created: new Date(msg.createdDateTime),
        mentions: members, // All participants for private thread visibility
      })),
    ...(initialSync ? { unread: false, archived: false } : {}),
  };
}

/**
 * Fetches channel messages with pagination and groups them into threads
 * (parent message + replies).
 */
export async function syncChannelMessages(
  api: GraphApi,
  teamId: string,
  state: SyncState
): Promise<{
  threads: Array<{ parent: TeamsMessage; replies: TeamsMessage[] }>;
  state: SyncState;
}> {
  const result = await api.getChannelMessages(teamId, state.channelId, {
    top: 50,
    skipToken: state.cursor,
  });

  const threads: Array<{ parent: TeamsMessage; replies: TeamsMessage[] }> = [];

  for (const message of result.value) {
    // Skip system messages
    if (message.messageType !== "message") continue;

    // Filter by oldest timestamp if set
    if (
      state.oldest &&
      new Date(message.createdDateTime) < new Date(state.oldest)
    ) {
      continue;
    }

    // Fetch replies for this message
    const replies = await api.getMessageReplies(
      teamId,
      state.channelId,
      message.id
    );

    threads.push({ parent: message, replies });
  }

  const nextLink = result["@odata.nextLink"];

  return {
    threads,
    state: {
      channelId: state.channelId,
      cursor: nextLink,
      more: !!nextLink,
      oldest: state.oldest,
      initialSync: state.initialSync,
    },
  };
}
