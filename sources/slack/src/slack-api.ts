import type {
  NewLinkWithNotes,
  NewActor,
} from "@plotday/twister/plot";

export type SlackChannel = {
  id: string;
  name: string;
  is_channel: boolean;
  is_group: boolean;
  is_private: boolean;
  is_archived: boolean;
  is_member: boolean;
  topic?: {
    value: string;
  };
  purpose?: {
    value: string;
  };
};

export type SlackMessage = {
  type: string;
  subtype?: string;
  ts: string;
  thread_ts?: string;
  user?: string;
  bot_id?: string;
  text: string;
  reactions?: Array<{
    name: string;
    users: string[];
    count: number;
  }>;
  files?: Array<{
    id: string;
    name: string;
    mimetype: string;
    url_private: string;
  }>;
  reply_count?: number;
  reply_users_count?: number;
};

export type SlackUser = {
  id: string;
  name: string;
  real_name?: string;
  profile?: {
    email?: string;
    display_name?: string;
    real_name?: string;
    image_72?: string;
  };
};

export type SyncState = {
  channelId: string;
  cursor?: string;
  more?: boolean;
  oldest?: string;
  latest?: string;
};

export class SlackApi {
  constructor(public accessToken: string) {}

  public async call(
    method: string,
    params?: { [key: string]: any }
  ): Promise<any> {
    const url = `https://slack.com/api/${method}`;
    const headers = {
      Authorization: `Bearer ${this.accessToken}`,
      "Content-Type": "application/json; charset=utf-8",
    };

    const response = await fetch(url, {
      method: "POST",
      headers,
      body: JSON.stringify(params || {}),
    });

    if (!response.ok) {
      throw new Error(
        `Slack API error: ${response.status} ${response.statusText}`
      );
    }

    const data = await response.json();

    if (!data.ok) {
      throw new Error(`Slack API error: ${data.error}`);
    }

    return data;
  }

  public async getChannels(): Promise<SlackChannel[]> {
    const publicChannels = await this.call("conversations.list", {
      types: "public_channel",
      exclude_archived: true,
      limit: 200,
    });

    const privateChannels = await this.call("conversations.list", {
      types: "private_channel",
      exclude_archived: true,
      limit: 200,
    });

    return [
      ...(publicChannels.channels || []),
      ...(privateChannels.channels || []),
    ];
  }

  public async getUser(userId: string): Promise<SlackUser | null> {
    try {
      const data = await this.call("users.info", { user: userId });
      return data.user || null;
    } catch (error) {
      return null;
    }
  }

  public async getConversationHistory(
    channelId: string,
    cursor?: string,
    oldest?: string,
    latest?: string
  ): Promise<{
    messages: SlackMessage[];
    hasMore: boolean;
    nextCursor?: string;
  }> {
    const params: any = {
      channel: channelId,
      limit: 100,
    };

    if (cursor) {
      params.cursor = cursor;
    }
    if (oldest) {
      params.oldest = oldest;
    }
    if (latest) {
      params.latest = latest;
    }

    const data = await this.call("conversations.history", params);

    return {
      messages: data.messages || [],
      hasMore: data.has_more || false,
      nextCursor: data.response_metadata?.next_cursor,
    };
  }

  public async getThreadReplies(
    channelId: string,
    threadTs: string
  ): Promise<SlackMessage[]> {
    const data = await this.call("conversations.replies", {
      channel: channelId,
      ts: threadTs,
    });

    // First message in replies is always the parent, so we skip it
    return (data.messages || []).slice(1);
  }
}

/**
 * Parses user mentions from Slack message text
 * Slack mentions have the format <@USER_ID>
 */
function parseUserMentions(text: string): string[] {
  const mentionRegex = /<@([A-Z0-9]+)>/g;
  const mentions: string[] = [];
  let match;

  while ((match = mentionRegex.exec(text)) !== null) {
    mentions.push(match[1]);
  }

  return mentions;
}

/**
 * Parses user mentions and returns NewActor[] for the mentions field.
 */
function parseUserMentionNewActors(text: string): NewActor[] {
  const userIds = parseUserMentions(text);
  return userIds.map((userId) => ({
    id: `slack:${userId}` as any,
  }));
}

/**
 * Converts a Slack user ID to a NewActor.
 */
function slackUserToNewActor(userId: string): NewActor {
  return {
    id: `slack:${userId}` as any,
  };
}

/**
 * Converts Slack markdown to plain text for better readability
 */
function formatSlackText(text: string): string {
  return (
    text
      // Convert user mentions
      .replace(/<@([A-Z0-9]+)>/g, "@$1")
      // Convert channel mentions
      .replace(/<#([A-Z0-9]+)\|([^>]+)>/g, "#$2")
      // Convert links
      .replace(/<(https?:\/\/[^|>]+)\|([^>]+)>/g, "$2 ($1)")
      .replace(/<(https?:\/\/[^>]+)>/g, "$1")
      // Convert bold
      .replace(/\*([^*]+)\*/g, "**$1**")
      // Convert italic
      .replace(/_([^_]+)_/g, "*$1*")
      // Convert strikethrough
      .replace(/~([^~]+)~/g, "~~$1~~")
      // Convert code
      .replace(/`([^`]+)`/g, "`$1`")
  );
}

/**
 * Transforms a Slack message thread into a NewLinkWithNotes structure.
 * The first message snippet becomes the link title, and each message becomes a Note.
 */
export function transformSlackThread(
  messages: SlackMessage[],
  channelId: string
): NewLinkWithNotes {
  const parentMessage = messages[0];

  if (!parentMessage) {
    // Return empty structure for invalid threads
    return {
      type: "message",
      title: "Empty thread",
      notes: [],
    };
  }

  const threadTs = parentMessage.thread_ts || parentMessage.ts;
  const firstText = formatSlackText(parentMessage.text);
  const title = firstText.substring(0, 50) || "Slack message";

  // Canonical URL using Slack's app_redirect (works across all workspaces)
  const canonicalUrl = `https://slack.com/app_redirect?channel=${channelId}&message_ts=${threadTs}`;

  // Create link
  const thread: NewLinkWithNotes = {
    source: canonicalUrl,
    type: "message",
    title,
    created: new Date(parseFloat(parentMessage.ts) * 1000),
    meta: {
      channelId: channelId,
      threadTs: threadTs,
    },
    notes: [],
    preview: firstText || null,
  };

  // Create Notes for all messages (including first)
  for (const message of messages) {
    const userId = message.user || message.bot_id;
    if (!userId) continue; // Skip messages without user

    const text = formatSlackText(message.text);
    const mentions = parseUserMentionNewActors(message.text);

    // Create NewNote with idempotent key
    const note = {
      key: message.ts,
      author: slackUserToNewActor(userId),
      content: text,
      mentions: mentions.length > 0 ? mentions : undefined,
    };

    thread.notes!.push(note);
  }

  return thread;
}

/**
 * Syncs messages from a Slack channel with cursor-based pagination
 * Returns message threads and updated sync state
 */
export async function syncSlackChannel(
  api: SlackApi,
  state: SyncState
): Promise<{
  threads: SlackMessage[][];
  state: SyncState;
}> {
  const { messages, hasMore, nextCursor } = await api.getConversationHistory(
    state.channelId,
    state.cursor,
    state.oldest,
    state.latest
  );

  // Group messages by thread
  const threadMap = new Map<string, SlackMessage[]>();

  for (const message of messages) {
    // Skip certain message subtypes
    if (
      message.subtype === "channel_join" ||
      message.subtype === "channel_leave"
    ) {
      continue;
    }

    const threadTs = message.thread_ts || message.ts;

    if (!threadMap.has(threadTs)) {
      threadMap.set(threadTs, []);
    }

    threadMap.get(threadTs)!.push(message);
  }

  // Fetch thread replies for messages that have threads
  const threads: SlackMessage[][] = [];

  for (const [threadTs, messagesInThread] of threadMap.entries()) {
    const parentMessage = messagesInThread.find((m) => m.ts === threadTs);

    if (
      parentMessage &&
      parentMessage.reply_count &&
      parentMessage.reply_count > 0
    ) {
      // Fetch all replies for this thread
      const replies = await api.getThreadReplies(state.channelId, threadTs);
      threads.push([parentMessage, ...replies]);
    } else {
      // No replies, just the parent message
      threads.push(messagesInThread);
    }
  }

  const newState: SyncState = {
    channelId: state.channelId,
    cursor: nextCursor,
    more: hasMore,
    oldest: state.oldest,
    latest: state.latest,
  };

  return {
    threads,
    state: newState,
  };
}
