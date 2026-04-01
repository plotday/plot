import type {
  NewLinkWithNotes,
  NewActor,
} from "@plotday/twister/plot";
import { AuthProvider } from "@plotday/twister/tools/integrations";

// ---- Google Chat API types ----

export type Space = {
  name: string;
  displayName: string;
  type: "ROOM" | "DM" | "SPACE";
  spaceType: "SPACE" | "GROUP_CHAT" | "DIRECT_MESSAGE";
  singleUserBotDm?: boolean;
  spaceThreadingState?: "THREADED_MESSAGES" | "GROUPED_MESSAGES" | "UNTHREADED_MESSAGES";
  spaceDetails?: {
    description?: string;
    guidelines?: string;
  };
};

export type Message = {
  name: string;
  sender: MessageSender;
  createTime: string;
  lastUpdateTime?: string;
  deleteTime?: string;
  text?: string;
  formattedText?: string;
  thread: {
    name: string;
    threadKey?: string;
  };
  space: {
    name: string;
  };
  attachment?: Attachment[];
  clientAssignedMessageId?: string;
};

export type MessageSender = {
  name: string;
  displayName: string;
  domainId?: string;
  type: "HUMAN" | "BOT";
};

export type Attachment = {
  name: string;
  contentName: string;
  contentType: string;
  driveDataRef?: {
    driveFileId: string;
  };
  thumbnailUri?: string;
  downloadUri?: string;
};

export type Member = {
  name: string;
  member: {
    name: string;
    displayName: string;
    domainId?: string;
    type: "HUMAN" | "BOT";
    email?: string;
  };
  role: "ROLE_MEMBER" | "ROLE_MANAGER";
  state: "MEMBER_JOINED" | "MEMBER_INVITED" | "MEMBER_NOT_A_MEMBER";
  createTime: string;
};

export type Subscription = {
  name: string;
  uid?: string;
  targetResource: string;
  eventTypes: string[];
  notificationEndpoint: {
    pubsubTopic: string;
  };
  state?: "ACTIVE" | "SUSPENDED" | "DELETED";
  expireTime: string;
  ttl?: string;
};

export type SyncState = {
  channelId: string;
  pageToken?: string;
  initialSync: boolean;
};

// ---- API client ----

export class GoogleChatApi {
  private chatBaseUrl = "https://chat.googleapis.com/v1";
  private workspaceEventsBaseUrl = "https://workspaceevents.googleapis.com/v1";

  constructor(public accessToken: string) {}

  private async call(
    url: string,
    options?: {
      method?: string;
      params?: Record<string, string | number | boolean | undefined>;
      body?: unknown;
    }
  ): Promise<any> {
    const method = options?.method ?? "GET";
    const params = options?.params ?? {};
    const body = options?.body;

    const reqUrl = new URL(url);
    for (const [key, value] of Object.entries(params)) {
      if (value !== undefined && value !== null) {
        reqUrl.searchParams.append(key, String(value));
      }
    }

    const response = await fetch(reqUrl.toString(), {
      method,
      headers: {
        Authorization: `Bearer ${this.accessToken}`,
        "Content-Type": "application/json",
      },
      body: body ? JSON.stringify(body) : undefined,
    });

    if (!response.ok) {
      const errorText = await response.text();
      throw new Error(
        `Google Chat API error: ${response.status} ${response.statusText} - ${errorText}`
      );
    }

    // Some endpoints return empty responses (204)
    const text = await response.text();
    return text ? JSON.parse(text) : {};
  }

  // ---- Spaces ----

  async listSpaces(filter?: string): Promise<Space[]> {
    const spaces: Space[] = [];
    let pageToken: string | undefined;

    do {
      const data = await this.call(`${this.chatBaseUrl}/spaces`, {
        params: { filter, pageToken, pageSize: 100 },
      });
      if (data.spaces) spaces.push(...data.spaces);
      pageToken = data.nextPageToken;
    } while (pageToken);

    return spaces;
  }

  // ---- Messages ----

  async listMessages(
    spaceName: string,
    options?: {
      pageSize?: number;
      pageToken?: string;
      filter?: string;
      orderBy?: string;
      showDeleted?: boolean;
    }
  ): Promise<{ messages: Message[]; nextPageToken?: string }> {
    const data = await this.call(`${this.chatBaseUrl}/${spaceName}/messages`, {
      params: {
        pageSize: options?.pageSize ?? 100,
        pageToken: options?.pageToken,
        filter: options?.filter,
        orderBy: options?.orderBy ?? "createTime ASC",
        showDeleted: options?.showDeleted,
      },
    });

    return {
      messages: data.messages ?? [],
      nextPageToken: data.nextPageToken,
    };
  }

  async createMessage(
    spaceName: string,
    text: string,
    threadName?: string
  ): Promise<Message> {
    const body: Record<string, unknown> = { text };
    if (threadName) {
      body.thread = { name: threadName };
    }

    return await this.call(`${this.chatBaseUrl}/${spaceName}/messages`, {
      method: "POST",
      params: threadName ? { messageReplyOption: "REPLY_MESSAGE_FALLBACK_TO_NEW_THREAD" } : {},
      body,
    });
  }

  // ---- Members ----

  async listMembers(spaceName: string): Promise<Member[]> {
    const members: Member[] = [];
    let pageToken: string | undefined;

    do {
      const data = await this.call(`${this.chatBaseUrl}/${spaceName}/members`, {
        params: { pageToken, pageSize: 100 },
      });
      if (data.memberships) members.push(...data.memberships);
      pageToken = data.nextPageToken;
    } while (pageToken);

    return members;
  }

  // ---- Workspace Events API — Subscriptions ----

  async createSubscription(
    targetResource: string,
    pubsubTopic: string,
    eventTypes: string[]
  ): Promise<Subscription> {
    const data = await this.call(`${this.workspaceEventsBaseUrl}/subscriptions`, {
      method: "POST",
      body: {
        targetResource: `//chat.googleapis.com/${targetResource}`,
        eventTypes,
        notificationEndpoint: { pubsubTopic },
        // 7-day TTL (maximum for Workspace Events)
        ttl: "604800s",
      },
    });

    // createSubscription returns a long-running operation (LRO).
    // If completed immediately, data.response contains the subscription.
    if (data.response) return data.response;

    // Poll the operation until done (max 5 attempts, 1s delay)
    if (data.name) {
      for (let i = 0; i < 5; i++) {
        await new Promise((r) => setTimeout(r, 1000));
        const op = await this.call(
          `${this.workspaceEventsBaseUrl}/${data.name}`
        );
        if (op.done && op.response) return op.response;
        if (op.error) {
          throw new Error(
            `Subscription creation failed: ${op.error.message ?? JSON.stringify(op.error)}`
          );
        }
      }
    }

    // Return best available data if operation hasn't completed
    return data.metadata?.subscription ?? data;
  }

  async renewSubscription(subscriptionName: string): Promise<Subscription> {
    return await this.call(
      `${this.workspaceEventsBaseUrl}/${subscriptionName}:reactivate`,
      { method: "POST" }
    );
  }

  async deleteSubscription(subscriptionName: string): Promise<void> {
    await this.call(`${this.workspaceEventsBaseUrl}/${subscriptionName}`, {
      method: "DELETE",
    });
  }
}

// ---- Helpers ----

/**
 * Extracts the space ID from a resource name like "spaces/AAAA".
 */
export function extractSpaceId(spaceName: string): string {
  return spaceName.replace(/^spaces\//, "");
}

/**
 * Converts a bare space ID back to a resource name: "AAAA" → "spaces/AAAA".
 * Idempotent: "spaces/AAAA" → "spaces/AAAA".
 */
export function toSpaceName(spaceId: string): string {
  return spaceId.startsWith("spaces/") ? spaceId : `spaces/${spaceId}`;
}

/**
 * Extracts the thread key from a thread name like "spaces/AAAA/threads/BBBB".
 */
export function extractThreadKey(threadName: string): string {
  const parts = threadName.split("/");
  return parts[parts.length - 1];
}

/**
 * Extracts the message ID from a message name like "spaces/AAAA/messages/CCCC".
 */
export function extractMessageId(messageName: string): string {
  const parts = messageName.split("/");
  return parts[parts.length - 1];
}

export type MemberInfo = {
  email?: string;
  displayName?: string;
};

/**
 * Converts a Google Chat sender into a NewActor for Plot.
 * Uses the sender's display name; email and name are resolved via membership data.
 * Always provides at least a name so contacts are never "Unknown".
 */
export function senderToNewActor(
  sender: MessageSender,
  memberInfo?: Map<string, MemberInfo>
): NewActor {
  const info = memberInfo?.get(sender.name);
  const email = info?.email;
  // Use sender displayName first, fall back to membership displayName,
  // then fall back to the user resource name (e.g. "users/12345…")
  const name = sender.displayName || info?.displayName || sender.name;
  return {
    name,
    ...(email ? { email } : {}),
    source: { provider: AuthProvider.Google, accountId: sender.name },
  };
}

/**
 * Groups a flat list of messages by their thread name.
 */
export function groupMessagesByThread(
  messages: Message[]
): Map<string, Message[]> {
  const groups = new Map<string, Message[]>();

  for (const message of messages) {
    const threadName = message.thread.name;
    if (!groups.has(threadName)) {
      groups.set(threadName, []);
    }
    groups.get(threadName)!.push(message);
  }

  return groups;
}

/**
 * Transforms a group of Google Chat messages (one thread) into a NewLinkWithNotes.
 */
export function transformChatThread(
  messages: Message[],
  spaceId: string,
  initialSync: boolean,
  memberInfo?: Map<string, MemberInfo>,
  members?: NewActor[]
): NewLinkWithNotes {
  const firstMessage = messages[0];
  const threadKey = extractThreadKey(firstMessage.thread.name);

  const title =
    firstMessage.text?.substring(0, 100) ?? "Chat message";

  // Plain-text preview from first message (never HTML)
  const preview = firstMessage.text?.substring(0, 200) ?? null;

  return {
    source: `google-chat:${spaceId}:thread:${threadKey}`,
    type: "message",
    title,
    private: true,
    created: new Date(firstMessage.createTime),
    author: senderToNewActor(firstMessage.sender, memberInfo),
    sourceUrl: null,
    meta: {
      spaceId,
      spaceName: firstMessage.space.name,
      threadName: firstMessage.thread.name,
      threadKey,
    },
    notes: messages.map((msg) => ({
      key: `message-${extractMessageId(msg.name)}`,
      content: msg.formattedText ?? msg.text ?? null,
      contentType: msg.formattedText ? ("html" as const) : ("text" as const),
      created: new Date(msg.createTime),
      author: senderToNewActor(msg.sender, memberInfo),
      ...(members && members.length > 0 ? { mentions: members } : {}),
    })),
    preview,
    ...(initialSync ? { unread: false, archived: false } : {}),
  };
}

/**
 * Fetches a page of messages from a space and returns them grouped by thread.
 */
export async function syncChatSpace(
  api: GoogleChatApi,
  state: SyncState,
  batchSize: number = 100
): Promise<{
  threads: Message[][];
  state: SyncState;
  hasMore: boolean;
}> {
  const { messages, nextPageToken } = await api.listMessages(toSpaceName(state.channelId), {
    pageSize: batchSize,
    pageToken: state.pageToken,
  });

  const groups = groupMessagesByThread(messages);
  const threads = Array.from(groups.values());

  const newState: SyncState = {
    channelId: state.channelId,
    pageToken: nextPageToken,
    initialSync: state.initialSync,
  };

  return {
    threads,
    state: newState,
    hasMore: !!nextPageToken,
  };
}
