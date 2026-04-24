import type {
  NewLinkWithNotes,
  NewActor,
  NewTags,
} from "@plotday/twister/plot";
import { Tag } from "@plotday/twister/tag";
import { AuthProvider } from "@plotday/twister/tools/integrations";

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

export type StarsListItem = {
  type: string;
  channel?: string;
  message?: {
    ts: string;
    thread_ts?: string;
  };
};

/**
 * Thrown when Slack rate-limits a call. Callers should catch this and
 * reschedule via `runTask(cb, { runAt })` rather than retry in-process —
 * Slack's `conversations.*` rate limits for non-Marketplace apps are 1 rpm,
 * so waits are typically too long to burn worker CPU on.
 */
export class SlackRateLimitedError extends Error {
  constructor(
    public readonly method: string,
    public readonly retryAfterMs: number
  ) {
    super(
      `Slack rate limited on ${method}; retry after ${retryAfterMs}ms`
    );
    this.name = "SlackRateLimitedError";
  }
}

function parseRetryAfterMs(header: string | null): number {
  // Slack documents Retry-After in seconds; fall back to 60s when missing
  // (their published default for `ratelimited`).
  if (!header) return 60_000;
  const n = parseInt(header, 10);
  if (!Number.isFinite(n) || n <= 0) return 60_000;
  return n * 1000;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export class SlackApi {
  constructor(public accessToken: string) {}

  public async call(
    method: string,
    params?: { [key: string]: any }
  ): Promise<any> {
    const url = `https://slack.com/api/${method}`;
    const headers = {
      Authorization: `Bearer ${this.accessToken}`,
      "Content-Type": "application/x-www-form-urlencoded; charset=utf-8",
    };

    // Slack Web API's canonical body format is form-urlencoded. JSON bodies
    // are accepted for some methods but not all (e.g. conversations.replies
    // rejected JSON with invalid_arguments under user tokens), so always
    // encode params as a form body.
    const body = new URLSearchParams();
    for (const [key, value] of Object.entries(params ?? {})) {
      if (value === undefined || value === null) continue;
      body.append(
        key,
        typeof value === "string" ? value : JSON.stringify(value)
      );
    }

    const response = await fetch(url, {
      method: "POST",
      headers,
      body: body.toString(),
    });

    // HTTP 429: rate limited. Respect Retry-After. Short waits (<=2s) are
    // retried in-process; longer ones bubble up so the enclosing task can
    // reschedule itself via runTask({ runAt }).
    if (response.status === 429) {
      const retryAfterMs = parseRetryAfterMs(
        response.headers.get("retry-after")
      );
      if (retryAfterMs <= 2_000) {
        await sleep(retryAfterMs);
        return this.call(method, params);
      }
      throw new SlackRateLimitedError(method, retryAfterMs);
    }

    if (!response.ok) {
      throw new Error(
        `Slack API error (${method}): ${response.status} ${response.statusText}`
      );
    }

    const data = await response.json();

    if (!data.ok) {
      // Slack also returns `ratelimited` as an application-level error on a
      // 200 response (usually with a Retry-After header). Treat it the same
      // as a 429 so the caller can reschedule.
      if (data.error === "ratelimited") {
        const retryAfterMs = parseRetryAfterMs(
          response.headers.get("retry-after")
        );
        throw new SlackRateLimitedError(method, retryAfterMs);
      }

      const details = data.response_metadata?.messages?.length
        ? ` (${data.response_metadata.messages.join("; ")})`
        : "";
      throw new Error(`Slack API error (${method}): ${data.error}${details}`);
    }

    return data;
  }

  public async getChannels(): Promise<SlackChannel[]> {
    // Single call with both channel types — Slack dedupes across types and
    // a user token sees both public channels and the private channels the
    // user is a member of. Two separate calls returned the same public
    // channels twice for some workspaces.
    const response = await this.call("conversations.list", {
      types: "public_channel,private_channel",
      exclude_archived: true,
      limit: 200,
    });
    return response.channels || [];
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

  public async getThread(
    channelId: string,
    threadTs: string
  ): Promise<SlackMessage[]> {
    // Returns the full thread: parent message first, then replies. Used by
    // backfills (saving a starred thread from scratch) that need the parent
    // too, whereas the incremental sync path already has the parent and just
    // wants replies.
    const data = await this.call("conversations.replies", {
      channel: channelId,
      ts: threadTs,
    });
    return (data.messages || []) as SlackMessage[];
  }

  public async getThreadReplies(
    channelId: string,
    threadTs: string
  ): Promise<SlackMessage[]> {
    // First message in replies is always the parent, so we skip it.
    const messages = await this.getThread(channelId, threadTs);
    return messages.slice(1);
  }

  public async postMessage(
    channelId: string,
    text: string,
    threadTs?: string
  ): Promise<SlackMessage> {
    const params: Record<string, string> = {
      channel: channelId,
      text,
    };
    if (threadTs) {
      params.thread_ts = threadTs;
    }
    const data = await this.call("chat.postMessage", params);
    return data.message;
  }

  /**
   * Edits a message via `chat.update`. Requires `chat:write` user scope and
   * the message must have been posted by the authenticated user.
   *
   * Returns Slack's echoed representation (post-edit), whose `text` field is
   * the authoritative stored mrkdwn. Falls back to the caller's text if Slack
   * doesn't include a `message` envelope in the response.
   */
  public async updateMessage(
    channelId: string,
    ts: string,
    text: string
  ): Promise<{ ts: string; text: string }> {
    const data = await this.call("chat.update", {
      channel: channelId,
      ts,
      text,
    });
    // `chat.update` returns `{ ok, channel, ts, text, message: { text, ... } }`.
    // The message envelope may be absent under some tokens; fall back to the
    // top-level `text` and `ts`.
    const echoed =
      (data.message && typeof data.message.text === "string"
        ? data.message.text
        : undefined) ?? (typeof data.text === "string" ? data.text : text);
    const echoedTs = (typeof data.ts === "string" ? data.ts : ts) as string;
    return { ts: echoedTs, text: echoed };
  }

  public async addStar(channelId: string, timestamp: string): Promise<void> {
    await this.call("stars.add", { channel: channelId, timestamp });
  }

  public async removeStar(channelId: string, timestamp: string): Promise<void> {
    try {
      await this.call("stars.remove", { channel: channelId, timestamp });
    } catch (error) {
      // stars.remove returns `not_starred` when the item isn't saved;
      // treat as idempotent success.
      const message = error instanceof Error ? error.message : String(error);
      if (!message.includes("not_starred")) throw error;
    }
  }

  public async listStars(cursor?: string): Promise<{
    items: StarsListItem[];
    nextCursor?: string;
  }> {
    const params: Record<string, string | number> = { limit: 100 };
    if (cursor) params.cursor = cursor;
    const data = await this.call("stars.list", params);
    return {
      items: (data.items ?? []) as StarsListItem[],
      nextCursor: data.response_metadata?.next_cursor,
    };
  }
}

/**
 * Info resolved from Slack's `users.info` that we copy onto actors so Plot
 * contacts carry a real name/email instead of the opaque `U…` user id.
 */
export type SlackUserInfo = {
  name: string | null;
  email: string | null;
};

export type SlackUserInfoMap = Map<string, SlackUserInfo>;

/**
 * Extract the best display name + email from a users.info response.
 * Prefers the human-readable `real_name`, falls back to `display_name`,
 * then the login `name`.
 */
export function slackUserInfoFromUser(user: SlackUser): SlackUserInfo {
  const name =
    user.profile?.real_name ||
    user.real_name ||
    user.profile?.display_name ||
    user.name ||
    null;
  const email = user.profile?.email || null;
  return { name, email };
}

/**
 * Converts a Slack user ID to a NewActor.
 *
 * When `info` is provided (resolved via users.info), the actor carries the
 * user's real name and email so the Plot contact row gets meaningful
 * identity info. Without it we fall back to the Slack user id as the name,
 * which keeps the actor upsertable by `source` but displays poorly — callers
 * should prefetch user info whenever possible.
 */
function slackUserToNewActor(userId: string, info?: SlackUserInfo): NewActor {
  const source = { provider: AuthProvider.Slack, accountId: userId };
  if (info?.email && info.name) {
    return { name: info.name, email: info.email, source };
  }
  if (info?.email) {
    return { email: info.email, source };
  }
  if (info?.name) {
    return { name: info.name, source };
  }
  // Fallback: no info available. `NewContact` requires at least one of
  // `email` or `name`, so use the user id as the name — same as the
  // pre-resolver behavior.
  return { name: userId, source };
}

/**
 * Converts Slack markdown to plain text for better readability.
 * Exported so write-back paths can apply the same transform to Slack's
 * echoed `text` when producing the sync baseline (see `Slack.onNoteCreated`
 * / `onNoteUpdated`) — baseline must match what sync-in stores.
 */
export function formatSlackText(text: string): string {
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
 * Maps common Slack reaction names to Plot Count Tags.
 */
const SLACK_REACTION_TO_TAG: Record<string, Tag> = {
  "+1": Tag.Yes,
  thumbsup: Tag.Yes,
  "-1": Tag.No,
  thumbsdown: Tag.No,
  tada: Tag.Tada,
  fire: Tag.Fire,
  heart: Tag.Love,
  rocket: Tag.Rocket,
  sparkles: Tag.Sparkles,
  pray: Tag.Thanks,
  raised_hands: Tag.Thanks,
  smile: Tag.Smile,
  grinning: Tag.Smile,
  wave: Tag.Wave,
  clap: Tag.Applause,
  sunglasses: Tag.Cool,
  cry: Tag.Sad,
  sob: Tag.Sad,
  eyes: Tag.Looking,
  "100": Tag.Totally,
  star: Tag.Star,
  bulb: Tag.Idea,
};

/**
 * Extracts reaction tags from all messages in a thread.
 */
function extractSlackReactionTags(
  messages: SlackMessage[],
  userInfos?: SlackUserInfoMap
): NewTags | undefined {
  const tagActors = new Map<Tag, NewActor[]>();

  for (const msg of messages) {
    if (!msg.reactions) continue;
    for (const reaction of msg.reactions) {
      const tag = SLACK_REACTION_TO_TAG[reaction.name];
      if (!tag) continue;

      const actors = reaction.users.map((userId) =>
        slackUserToNewActor(userId, userInfos?.get(userId))
      );
      const existing = tagActors.get(tag) ?? [];
      tagActors.set(tag, [...existing, ...actors]);
    }
  }

  if (tagActors.size === 0) return undefined;

  const tags: NewTags = {};
  for (const [tag, actors] of tagActors) {
    // Deduplicate actors by source accountId
    const seen = new Set<string>();
    tags[tag] = actors.filter((a) => {
      const key = "source" in a ? a.source?.accountId : "id" in a ? a.id : "";
      if (!key || seen.has(key)) return false;
      seen.add(key);
      return true;
    });
  }
  return tags;
}

/**
 * Transforms a Slack message thread into a NewLinkWithNotes structure.
 * The first message snippet becomes the link title, and each message becomes a Note.
 */
export function transformSlackThread(
  messages: SlackMessage[],
  channelId: string,
  userInfos?: SlackUserInfoMap,
  initialSync?: boolean
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

  // Extract reaction tags from all messages
  const reactionTags = extractSlackReactionTags(messages, userInfos);

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
    sourceUrl: canonicalUrl,
    notes: [],
    ...(reactionTags ? { tags: reactionTags } : {}),
    preview: firstText || null,
    ...(initialSync ? { unread: false, archived: false } : {}),
  };

  // Create Notes for all messages (including first)
  for (const message of messages) {
    const userId = message.user || message.bot_id;
    if (!userId) continue; // Skip messages without user

    const text = formatSlackText(message.text);

    // Create NewNote with idempotent key
    const note = {
      key: message.ts,
      author: slackUserToNewActor(userId, userInfos?.get(userId)),
      content: text,
      created: new Date(parseFloat(message.ts) * 1000),
      checkForTasks: true,
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
      // One malformed thread_ts or a permission quirk on a single parent
      // (e.g. `invalid_arguments` / `thread_not_found`) used to surface from
      // `conversations.replies` and abort the whole batch, wedging sync on
      // that cursor indefinitely. Degrade to the parent-only path so the
      // rest of the channel still advances.
      try {
        const replies = await api.getThreadReplies(state.channelId, threadTs);
        threads.push([parentMessage, ...replies]);
      } catch (error) {
        console.warn(
          `conversations.replies failed for ${state.channelId}/${threadTs}; falling back to parent-only`,
          error
        );
        threads.push([parentMessage]);
      }
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
