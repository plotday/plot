import type { ChatProfile } from "./messaging";
import type { NewActor, NewNote, NewReactions } from "@plotday/twister/plot";
import type { NewLinkWithNotes } from "@plotday/twister";
import { profileToContact } from "./connector-helpers";

/** A post authored on LinkedIn (the connected account's own feed post). */
export type LinkedInPost = {
  /** LinkedIn social id, e.g. "urn:li:activity:7332661864792854528". */
  id: string;
  text: string;
  createdAt: Date;
  author: ChatProfile;
  url: string | null;
};

/** A comment (or reply) on a post. `parentCommentId` null = top-level. */
export type LinkedInComment = {
  id: string;
  text: string;
  createdAt: Date;
  author: ChatProfile;
  parentCommentId: string | null;
};

/** A single reactor on a post or comment. */
export type LinkedInPostReaction = {
  reactorId: string;
  reactorName: string | null;
  reactorPictureUrl: string | null;
  /** LinkedIn reaction type string, e.g. "like" | "celebrate" | … (LIVE-CONFIRM). */
  reactionType: string;
};

/** Binary attachment for a composed post or comment. */
export type PostAttachment = { buffer: Uint8Array; filename: string; mimeType: string };

/**
 * The LinkedIn connection exposes two channels backed by the same Unipile
 * account: the DM inbox (id === accountId) and Public Post (id ===
 * `${accountId}#posts`). The suffix keeps the two channel ids distinct while
 * still recovering the raw Unipile account id for API calls.
 */
export const POSTS_CHANNEL_SUFFIX = "#posts";
export const postsChannelId = (accountId: string): string =>
  `${accountId}${POSTS_CHANNEL_SUFFIX}`;
export const accountIdFromChannel = (channelId: string): string =>
  channelId.endsWith(POSTS_CHANNEL_SUFFIX)
    ? channelId.slice(0, -POSTS_CHANNEL_SUFFIX.length)
    : channelId;

/**
 * LinkedIn's fixed post/comment reaction set (distinct from the 7-emoji DM
 * set). Emoji → Unipile `reaction_type` string is LIVE-CONFIRM.
 */
const POST_REACTION_TYPE_BY_EMOJI: Record<string, string> = {
  "👍": "like",
  "❤️": "love",
  "👏": "celebrate",
  "💡": "insightful",
  "😂": "funny",
  "🤝": "support",
};
const EMOJI_BY_POST_REACTION_TYPE: Record<string, string> = Object.fromEntries(
  Object.entries(POST_REACTION_TYPE_BY_EMOJI).map(([emoji, type]) => [type, emoji])
);

export const LINKEDIN_POST_REACTIONS = Object.keys(
  POST_REACTION_TYPE_BY_EMOJI
) as readonly string[];

export const mapEmojiToPostReactionType = (emoji: string): string | null =>
  POST_REACTION_TYPE_BY_EMOJI[emoji] ?? null;
export const mapPostReactionTypeToEmoji = (type: string): string | null =>
  EMOJI_BY_POST_REACTION_TYPE[type] ?? null;

const PROVIDER = "linkedin";

export const postThreadSource = (postId: string): string => `${PROVIDER}:post:${postId}`;
export const postBodyNoteKey = (postId: string): string => `post-${postId}`;
export const commentNoteKey = (commentId: string): string => `comment-${commentId}`;

/** Group reactor entries into a Plot NewReactions map, capped to avoid
 * materializing viral reaction storms as thousands of contacts. */
export function buildReactionsFromPostReactions(
  reactions: LinkedInPostReaction[],
  cap = 50
): NewReactions | undefined {
  if (!reactions.length) return undefined;
  const out: NewReactions = {};
  let count = 0;
  for (const r of reactions) {
    if (count >= cap) break;
    const emoji = mapPostReactionTypeToEmoji(r.reactionType);
    if (!emoji) continue;
    const actor: NewActor = { name: r.reactorName ?? "LinkedIn user", source: { accountId: r.reactorId }, ...(r.reactorPictureUrl ? { avatar: r.reactorPictureUrl } : {}) };
    (out[emoji] ??= []).push(actor);
    count++;
  }
  return Object.keys(out).length ? out : undefined;
}

export function buildPostBodyNote(post: LinkedInPost, reactions?: LinkedInPostReaction[]): NewNote {
  const r = reactions ? buildReactionsFromPostReactions(reactions) : undefined;
  return {
    thread: { source: postThreadSource(post.id) },
    key: postBodyNoteKey(post.id),
    created: post.createdAt,
    content: post.text,
    contentType: "text",
    author: profileToContact(post.author),
    ...(r ? { reactions: r } : {}),
  } satisfies NewNote;
}

export function buildCommentNote(
  postId: string,
  comment: LinkedInComment,
  reactions?: LinkedInPostReaction[]
): NewNote {
  const r = reactions ? buildReactionsFromPostReactions(reactions) : undefined;
  return {
    thread: { source: postThreadSource(postId) },
    key: commentNoteKey(comment.id),
    created: comment.createdAt,
    content: comment.text,
    contentType: "text",
    author: profileToContact(comment.author),
    ...(comment.parentCommentId ? { reNote: { key: commentNoteKey(comment.parentCommentId) } } : {}),
    ...(r ? { reactions: r } : {}),
  } satisfies NewNote;
}

/** Short thread title from the post body: first non-empty line, truncated. */
function postTitle(text: string): string {
  const firstLine = (text.split("\n").find((l) => l.trim().length > 0) ?? "").trim();
  if (!firstLine) return "LinkedIn post";
  return firstLine.length > 80 ? `${firstLine.slice(0, 79)}…` : firstLine;
}

export function buildPostLink(opts: {
  accountId: string;
  channelId: string;
  post: LinkedInPost;
  comments: LinkedInComment[];
  postReactions?: LinkedInPostReaction[];
  commentReactions?: Map<string, LinkedInPostReaction[]>;
  initialSync: boolean;
}): NewLinkWithNotes {
  const { accountId, channelId, post, comments, initialSync } = opts;
  const notes: NewNote[] = [buildPostBodyNote(post, opts.postReactions)];
  for (const c of comments) {
    notes.push(buildCommentNote(post.id, c, opts.commentReactions?.get(c.id)));
  }
  return {
    source: postThreadSource(post.id),
    sources: [postThreadSource(post.id)],
    type: "post",
    title: postTitle(post.text),
    preview: post.text || null,
    sourceUrl: post.url,
    created: post.createdAt,
    accessContacts: [profileToContact(post.author)],
    notes,
    meta: { syncProvider: PROVIDER, accountId, channelId, postId: post.id },
    ...(initialSync ? { unread: false, archived: false } : {}),
  } satisfies NewLinkWithNotes;
}

const MINUTE_MS = 60_000;
const HOUR_MS = 60 * MINUTE_MS;
const DAY_MS = 24 * HOUR_MS;

/** Base (un-jittered) delay until the next comment poll, by post age. Returns
 * null once the post is older than 30 days (retire the poll). */
export function adaptivePollDelayMs(postCreatedAt: Date, now: Date): number | null {
  const age = now.getTime() - postCreatedAt.getTime();
  if (age < HOUR_MS) return 5 * MINUTE_MS;
  if (age < DAY_MS) return 30 * MINUTE_MS;
  if (age < 7 * DAY_MS) return 3 * HOUR_MS;
  if (age < 30 * DAY_MS) return DAY_MS;
  return null;
}
