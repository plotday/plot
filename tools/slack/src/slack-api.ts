import type { NewActivity, ActorId } from "@plotday/twister";
import { ActivityType } from "@plotday/twister";

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
      throw new Error(`Slack API error: ${response.status} ${response.statusText}`);
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
 * Converts Slack markdown to plain text for better readability
 */
function formatSlackText(text: string): string {
  return text
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
    .replace(/`([^`]+)`/g, "`$1`");
}

/**
 * Transforms a Slack message thread into an array of Activities
 * The first message is the parent, subsequent messages are replies
 */
export function transformSlackThread(
  messages: SlackMessage[],
  channelId: string
): NewActivity[] {
  if (messages.length === 0) return [];

  const activities: NewActivity[] = [];
  const parentMessage = messages[0];
  const threadTs = parentMessage.thread_ts || parentMessage.ts;

  // Create parent activity
  const parentActivity: NewActivity = {
    type: ActivityType.Task,
    title: formatSlackText(parentMessage.text).substring(0, 100) || "Slack message",
    note: formatSlackText(parentMessage.text),
    noteType: "markdown",
    start: new Date(parseFloat(parentMessage.ts) * 1000),
    meta: {
      source: `slack:${channelId}:${parentMessage.ts}`,
      channelId,
      messageTs: parentMessage.ts,
      threadTs,
      userId: parentMessage.user || parentMessage.bot_id,
      reactions: parentMessage.reactions,
    },
  };

  // Add user mentions
  const mentions = parseUserMentions(parentMessage.text);
  if (mentions.length > 0) {
    parentActivity.mentions = mentions as ActorId[];
  }

  activities.push(parentActivity);

  // Create activities for replies
  for (let i = 1; i < messages.length; i++) {
    const reply = messages[i];
    const replyActivity: NewActivity = {
      type: ActivityType.Task,
      title: formatSlackText(reply.text).substring(0, 100) || "Reply",
      note: formatSlackText(reply.text),
      noteType: "markdown",
      start: new Date(parseFloat(reply.ts) * 1000),
      parent: { id: `slack:${channelId}:${parentMessage.ts}` }, // Link to parent
      meta: {
        source: `slack:${channelId}:${reply.ts}`,
        channelId,
        messageTs: reply.ts,
        threadTs,
        userId: reply.user || reply.bot_id,
        reactions: reply.reactions,
      },
    };

    // Add user mentions for reply
    const replyMentions = parseUserMentions(reply.text);
    if (replyMentions.length > 0) {
      replyActivity.mentions = replyMentions as ActorId[];
    }

    activities.push(replyActivity);
  }

  return activities;
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

    if (parentMessage && parentMessage.reply_count && parentMessage.reply_count > 0) {
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
