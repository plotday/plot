import type {
  NewLinkWithNotes,
  NewActor,
  NewContact,
  NewReactions,
} from "@plotday/twister/plot";

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

export type Annotation = {
  type: "USER_MENTION" | "SLASH_COMMAND" | "RICH_LINK";
  startIndex?: number;
  length?: number;
  userMention?: {
    user: {
      name: string;
      displayName?: string;
      type?: "HUMAN" | "BOT";
    };
    type: "ADD" | "MENTION";
  };
};

export type EmojiReaction = {
  name: string;
  emoji: {
    unicode?: string;
    customEmoji?: {
      uid: string;
    };
  };
  user: {
    name: string;
    displayName?: string;
    type?: "HUMAN" | "BOT";
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
  annotations?: Annotation[];
  emojiReactionSummaries?: Array<{
    emoji: {
      unicode?: string;
      customEmoji?: { uid: string };
    };
    reactionCount?: number;
  }>;
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

  async getMessage(messageName: string): Promise<Message> {
    return await this.call(`${this.chatBaseUrl}/${messageName}`);
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

  /**
   * Patches an existing message's text via `messages.patch` (updateMask=text).
   * Callers must own the message (only messages authored by the authenticated
   * user can be edited under user auth). Returns the updated message resource.
   */
  async updateMessage(messageName: string, text: string): Promise<Message> {
    return await this.call(`${this.chatBaseUrl}/${messageName}`, {
      method: "PATCH",
      params: { updateMask: "text" },
      body: { text },
    });
  }

  // ---- Reactions ----

  /**
   * Lists all reactions on a message, with per-user data.
   */
  async listReactions(messageName: string): Promise<EmojiReaction[]> {
    const reactions: EmojiReaction[] = [];
    let pageToken: string | undefined;

    do {
      const data = await this.call(`${this.chatBaseUrl}/${messageName}/reactions`, {
        params: { pageToken, pageSize: 100 },
      });
      if (data.reactions) reactions.push(...data.reactions);
      pageToken = data.nextPageToken;
    } while (pageToken);

    return reactions;
  }

  /**
   * Creates a reaction on a message as the authenticated user.
   */
  async createReaction(messageName: string, emoji: string): Promise<EmojiReaction> {
    return await this.call(`${this.chatBaseUrl}/${messageName}/reactions`, {
      method: "POST",
      body: { emoji: { unicode: emoji } },
    });
  }

  /**
   * Deletes a reaction by its full resource name.
   */
  async deleteReaction(reactionName: string): Promise<void> {
    await this.call(`${this.chatBaseUrl}/${reactionName}`, {
      method: "DELETE",
    });
  }

  // ---- User Info ----

  /**
   * Fetches the authenticated user's profile via Google's userinfo endpoint.
   * Returns the user's Google ID (sub), email, and display name.
   */
  async getUserInfo(): Promise<{ sub: string; email: string; name?: string }> {
    const response = await fetch(
      "https://www.googleapis.com/oauth2/v3/userinfo",
      { headers: { Authorization: `Bearer ${this.accessToken}` } }
    );
    if (!response.ok) {
      throw new Error(`UserInfo error: ${response.status} ${response.statusText}`);
    }
    return response.json() as Promise<{ sub: string; email: string; name?: string }>;
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

  // ---- Read State ----

  /**
   * Creates a new Google Chat space (for group DMs with >1 recipient).
   * Used when there is no pre-existing space that can be found via setupSpace.
   */
  async createSpace(
    displayName: string | undefined,
    spaceType: "SPACE" | "GROUP_CHAT" | "DIRECT_MESSAGE",
    members: Array<{ member: { name: string; type: "HUMAN" | "BOT" } }>
  ): Promise<Space> {
    return await this.call(`${this.chatBaseUrl}/spaces:setup`, {
      method: "POST",
      body: {
        space: {
          ...(displayName ? { displayName } : {}),
          spaceType,
        },
        memberships: members,
      },
    });
  }

  /**
   * Finds or creates a DM space for two users via `spaces.setup`.
   * `callerName` is the authenticated user's resource name (e.g. "users/12345").
   * `recipientName` is the target user's resource name (e.g. "users/67890").
   * Returns the resulting space resource.
   */
  async setupDmSpace(
    callerName: string,
    recipientName: string
  ): Promise<Space> {
    return await this.call(`${this.chatBaseUrl}/spaces:setup`, {
      method: "POST",
      body: {
        space: {
          spaceType: "DIRECT_MESSAGE",
        },
        memberships: [
          { member: { name: callerName, type: "HUMAN" } },
          { member: { name: recipientName, type: "HUMAN" } },
        ],
      },
    });
  }

  /**
   * Updates the calling user's read state for a space.
   * Sets the last read time to now (marking all messages as read)
   * or to a past time (effectively marking as unread).
   */
  async updateSpaceReadState(
    spaceName: string,
    lastReadTime: string
  ): Promise<void> {
    await this.call(
      `${this.chatBaseUrl}/${spaceName}/spaceReadState`,
      {
        method: "PATCH",
        params: { updateMask: "lastReadTime" },
        body: { lastReadTime },
      }
    );
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
 * Strip the `users/` resource-name prefix Chat returns on `User.name` so the
 * `source.accountId` is the bare numeric Google user ID. That's the same
 * identifier Drive emits as `permissionId` and that other Google APIs use as
 * the OIDC `sub` claim, so contacts dedupe across Google connectors via
 * `contact_external_account`.
 */
export function googleUserIdToAccountId(name: string): string {
  return name.startsWith("users/") ? name.slice("users/".length) : name;
}

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
    source: { accountId: googleUserIdToAccountId(sender.name) },
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

// Note: mentions on notes are for twist/connector dispatch routing only.
// Person contacts should NOT be in mentions — use thread-level accessContacts
// for visibility. The thread already has accessContacts set to space members.

/**
 * Builds note-level reactions for a single message from Google Chat's
 * reaction data. Unicode emoji pass through directly; custom workspace
 * emojis are skipped for now (cached image_url support is a follow-up).
 *
 * When per-user reaction data is available (from listReactions API),
 * each reactor is attributed individually. Otherwise falls back to
 * emojiReactionSummaries and attributes to the message sender as a proxy.
 */
export function extractMessageReactions(
  msg: Message,
  reactions?: EmojiReaction[],
  memberInfo?: Map<string, MemberInfo>,
): NewReactions | undefined {
  const byEmoji = new Map<string, NewActor[]>();

  if (reactions && reactions.length > 0) {
    // Per-user reaction data available — filter to this message
    const msgId = msg.name;
    for (const reaction of reactions) {
      // Reaction name: spaces/{spaceId}/messages/{messageId}/reactions/{reactionId}
      if (reaction.name && !reaction.name.startsWith(msgId + "/")) continue;

      const unicode = reaction.emoji.unicode;
      if (!unicode) continue; // skip custom emojis until image caching lands

      const actor = reactionUserToNewActor(reaction.user, memberInfo);
      const existing = byEmoji.get(unicode) ?? [];
      existing.push(actor);
      byEmoji.set(unicode, existing);
    }
  } else if (msg.emojiReactionSummaries) {
    // Fall back to summary data — attribute to message sender as a proxy
    for (const summary of msg.emojiReactionSummaries) {
      const unicode = summary.emoji.unicode;
      if (!unicode) continue;

      const actor = senderToNewActor(msg.sender, memberInfo);
      const existing = byEmoji.get(unicode) ?? [];
      existing.push(actor);
      byEmoji.set(unicode, existing);
    }
  }

  if (byEmoji.size === 0) return undefined;

  const out: NewReactions = {};
  for (const [emoji, actors] of byEmoji) {
    // Deduplicate actors by source accountId
    const seen = new Set<string>();
    out[emoji] = actors.filter((a) => {
      const key = "source" in a && a.source ? a.source.accountId : "name" in a ? a.name : "";
      if (!key || seen.has(key)) return false;
      seen.add(key);
      return true;
    });
  }
  return out;
}

/**
 * Converts a reaction user reference to a NewActor.
 */
function reactionUserToNewActor(
  user: EmojiReaction["user"],
  memberInfo?: Map<string, MemberInfo>,
): NewActor {
  const info = memberInfo?.get(user.name);
  return {
    name: user.displayName || info?.displayName || user.name,
    ...(info?.email ? { email: info.email } : {}),
    source: { accountId: googleUserIdToAccountId(user.name) },
  };
}

/**
 * Builds attachment link markdown for a message's attachments.
 */
function formatAttachments(attachments: Attachment[] | undefined): string {
  if (!attachments || attachments.length === 0) return "";

  const links = attachments.map((att) => {
    if (att.driveDataRef?.driveFileId) {
      return `[${att.contentName}](https://drive.google.com/file/d/${att.driveDataRef.driveFileId})`;
    }
    if (att.downloadUri) {
      return `[${att.contentName}](${att.downloadUri})`;
    }
    return att.contentName;
  });

  return "\n\n" + links.join("\n");
}

/**
 * Transforms a group of Google Chat messages (one thread) into a NewLinkWithNotes.
 */
export function transformChatThread(
  messages: Message[],
  spaceId: string,
  initialSync: boolean,
  memberInfo?: Map<string, MemberInfo>,
  members?: NewActor[],
  reactions?: EmojiReaction[]
): NewLinkWithNotes {
  const firstMessage = messages[0];
  const threadKey = extractThreadKey(firstMessage.thread.name);

  const title =
    firstMessage.text?.substring(0, 100) ?? "Chat message";

  // Plain-text preview from first message (never HTML)
  const preview = firstMessage.text?.substring(0, 200) ?? null;

  return {
    source: `google-chat:${spaceId}:thread:${threadKey}`,
    type: "thread",
    title,
    access: "private",
    accessContacts: members?.filter((m): m is NewContact => !("id" in m)) ?? [],
    created: new Date(firstMessage.createTime),
    author: senderToNewActor(firstMessage.sender, memberInfo),
    sourceUrl: `https://chat.google.com/room/${spaceId}/${threadKey}`,
    meta: {
      spaceId,
      spaceName: firstMessage.space.name,
      threadName: firstMessage.thread.name,
      threadKey,
    },
    notes: messages.map((msg) => {
      const baseContent = msg.formattedText ?? msg.text ?? null;
      const attachmentMarkdown = formatAttachments(msg.attachment);
      const content = baseContent && attachmentMarkdown
        ? baseContent + attachmentMarkdown
        : baseContent;
      const messageReactions = extractMessageReactions(msg, reactions, memberInfo);

      return {
        key: `message-${extractMessageId(msg.name)}`,
        content,
        contentType: msg.formattedText ? ("html" as const) : ("text" as const),
        created: new Date(msg.createTime),
        author: senderToNewActor(msg.sender, memberInfo),
        ...(messageReactions ? { reactions: messageReactions } : {}),
        checkForTasks: true,
      };
    }),
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
