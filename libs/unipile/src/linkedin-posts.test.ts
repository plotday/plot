import { describe, expect, test } from "vitest";
import {
  POSTS_CHANNEL_SUFFIX,
  postsChannelId,
  accountIdFromChannel,
  LINKEDIN_POST_REACTIONS,
  mapEmojiToPostReactionType,
  mapPostReactionTypeToEmoji,
  postThreadSource, postBodyNoteKey, commentNoteKey,
  buildPostBodyNote, buildCommentNote, buildPostLink,
  buildReactionsFromPostReactions,
  adaptivePollDelayMs,
} from "./linkedin-posts";
import type { LinkedInPost, LinkedInComment, LinkedInPostReaction } from "./linkedin-posts";
import type { ChatProfile } from "./messaging";

describe("channel id helpers", () => {
  test("postsChannelId appends the suffix", () => {
    expect(postsChannelId("acct123")).toBe(`acct123${POSTS_CHANNEL_SUFFIX}`);
  });
  test("accountIdFromChannel strips the suffix", () => {
    expect(accountIdFromChannel("acct123#posts")).toBe("acct123");
  });
  test("accountIdFromChannel is identity for a bare account id", () => {
    expect(accountIdFromChannel("acct123")).toBe("acct123");
  });
});

describe("reaction maps", () => {
  test("every allowed emoji round-trips to a reaction type and back", () => {
    for (const emoji of LINKEDIN_POST_REACTIONS) {
      const type = mapEmojiToPostReactionType(emoji);
      expect(type).not.toBeNull();
      expect(mapPostReactionTypeToEmoji(type!)).toBe(emoji);
    }
  });
  test("unknown emoji maps to null", () => {
    expect(mapEmojiToPostReactionType("🥳")).toBeNull();
  });
  test("👍 maps to like", () => {
    expect(mapEmojiToPostReactionType("👍")).toBe("like");
  });
});

const prof = (o: Partial<ChatProfile>): ChatProfile => ({
  id: "p1", isSelf: false, name: "Alice", handle: null, subtitle: null,
  email: null, phone: null, pictureUrl: null, profileUrl: null, ...o,
});
const post: LinkedInPost = {
  id: "urn:li:activity:7", text: "Shipping today!",
  createdAt: new Date("2026-06-20T12:00:00Z"),
  author: prof({ id: "self", isSelf: true, name: "Kris" }), url: "https://x/7",
};

describe("key helpers", () => {
  test("stable keys", () => {
    expect(postThreadSource("A")).toBe("linkedin:post:A");
    expect(postBodyNoteKey("A")).toBe("post-A");
    expect(commentNoteKey("C")).toBe("comment-C");
  });
});

describe("buildPostBodyNote", () => {
  test("first note keyed post-<id>, authored by poster", () => {
    const n = buildPostBodyNote(post) as { key: string; thread: { source: string }; content: string; author?: { name?: string }; reNote?: unknown };
    expect(n.key).toBe("post-urn:li:activity:7");
    expect(n.content).toBe("Shipping today!");
    expect(n.thread.source).toBe("linkedin:post:urn:li:activity:7");
    expect(n.author?.name).toBe("Kris");
    expect(n.reNote).toBeUndefined();
  });
});

describe("buildCommentNote", () => {
  test("top-level comment has no reNote", () => {
    const c: LinkedInComment = { id: "c1", text: "nice", createdAt: new Date("2026-06-20T12:05:00Z"), author: prof({ id: "u2", name: "Ada" }), parentCommentId: null };
    const n = buildCommentNote(post.id, c) as { key: string; reNote?: unknown; author?: { name?: string } };
    expect(n.key).toBe("comment-c1");
    expect(n.reNote).toBeUndefined();
    expect(n.author?.name).toBe("Ada");
  });
  test("reply sets reNote to the parent comment key", () => {
    const c: LinkedInComment = { id: "c2", text: "ty", createdAt: new Date(), author: prof({ id: "u3", name: "Bo" }), parentCommentId: "c1" };
    const n = buildCommentNote(post.id, c) as { reNote?: { key: string } };
    expect(n.reNote).toEqual({ key: "comment-c1" });
  });
});

describe("buildPostLink", () => {
  test("assembles thread with body note first, then comments", () => {
    const comments: LinkedInComment[] = [
      { id: "c1", text: "nice", createdAt: new Date("2026-06-20T12:05:00Z"), author: prof({ id: "u2", name: "Ada" }), parentCommentId: null },
    ];
    const link = buildPostLink({ accountId: "acct", channelId: "acct#posts", post, comments, initialSync: true }) as { source: string; type: string; channelId: string | null; meta: { syncProvider: string; accountId: string; channelId: string; postId: string }; notes?: Array<{ key?: string }>; unread?: boolean };
    expect(link.source).toBe("linkedin:post:urn:li:activity:7");
    expect(link.type).toBe("post");
    expect(link.meta).toMatchObject({ syncProvider: "linkedin", accountId: "acct", channelId: "acct#posts", postId: "urn:li:activity:7" });
    expect(link.notes?.[0]?.key).toBe("post-urn:li:activity:7");
    expect(link.notes?.[1]?.key).toBe("comment-c1");
    expect(link.unread).toBe(false); // initialSync
    // Top-level channelId must be set (not just inside meta) — see the
    // matching assertion in connector-helpers.test.ts for why.
    expect(link.channelId).toBe("acct#posts");
  });
});

describe("buildReactionsFromPostReactions", () => {
  const r = (reactionType: string, id: string): LinkedInPostReaction => ({
    reactorId: id,
    reactorName: `User ${id}`,
    reactorPictureUrl: null,
    reactionType,
  });

  test("returns undefined for no reactions", () => {
    expect(buildReactionsFromPostReactions([])).toBeUndefined();
  });

  test("groups reactors by mapped emoji", () => {
    const out = buildReactionsFromPostReactions([r("like", "1"), r("like", "2"), r("love", "3")]);
    expect(out?.["👍"]).toHaveLength(2);
    expect(out?.["❤️"]).toHaveLength(1);
  });

  test("skips reaction types with no emoji mapping", () => {
    const out = buildReactionsFromPostReactions([r("like", "1"), r("mystery", "2")]);
    expect(Object.keys(out ?? {})).toEqual(["👍"]);
    expect(out?.["👍"]).toHaveLength(1);
  });

  test("caps materialized reactors at 50", () => {
    const many = Array.from({ length: 60 }, (_, i) => r("like", String(i)));
    const out = buildReactionsFromPostReactions(many);
    expect(out?.["👍"]).toHaveLength(50);
  });
});

describe("adaptivePollDelayMs", () => {
  const base = new Date("2026-06-20T12:00:00Z");
  const at = (ms: number) => new Date(base.getTime() + ms);
  const MIN = 60_000, HOUR = 60 * MIN, DAY = 24 * HOUR;
  test("fresh (<1h) → 5 min", () => expect(adaptivePollDelayMs(base, at(30 * MIN))).toBe(5 * MIN));
  test("<24h → 30 min", () => expect(adaptivePollDelayMs(base, at(3 * HOUR))).toBe(30 * MIN));
  test("<7d → 3h", () => expect(adaptivePollDelayMs(base, at(3 * DAY))).toBe(3 * HOUR));
  test("<30d → 1 day", () => expect(adaptivePollDelayMs(base, at(10 * DAY))).toBe(DAY));
  test(">30d → retire (null)", () => expect(adaptivePollDelayMs(base, at(31 * DAY))).toBeNull());
});
