# LinkedIn "Public Post" channel — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a second **Public Post** channel to the private LinkedIn connector — composing to it creates a public LinkedIn post, and each post (Plot- or LinkedIn-created) becomes a thread whose comments sync both ways with nested replies, reactions, and attachments.

**Architecture:** Testable post/comment logic lives as pure functions in `libs/unipile/src/linkedin-posts.ts` (tested with vitest, mirroring `connector-helpers.ts`). The privileged v2 Unipile HTTP calls go in `workers/api/src/twist/tools/unipile/{client,posts}.ts` and are surfaced on the existing `LinkedInMessaging` tool. The connector (`connectors/linkedin/src/linkedin.ts`) stays thin: it wires channels, `onCreateLink`, `onNoteCreated`, `onNoteReactionChanged`, and two polling loops. Two small **additive** Twister SDK fields and matching Flutter parsing enable per-link-type reaction pickers and compose attachments.

**Tech Stack:** TypeScript (connector, `libs/unipile`, `workers/api`), Cloudflare Workers, vitest; Dart/Flutter (`apps/plot`); Unipile REST API **v2** (`https://api.unipile.com/v2`, `account_id` in the path).

## Global Constraints

- **v2 Unipile only.** All new HTTP calls go through `UnipileClient` (`https://api.unipile.com/v2`, `account_id` in the path). Exact post/comment/reaction routes and the `reaction_type` enum strings are **`LIVE-CONFIRM`** — mark them so and verify against the live v2 API before shipping.
- **Never `DELETE` synced rows** — connectors save via `integrations.save*`; no raw DB writes.
- **Error capture:** every `catch` for an *unexpected* error calls `tracker.captureException(error)` / `postHog.captureException(error, distinctId)` (workers) or `Tracker.captureException` (Flutter). Expected failures (rate limits, best-effort reaction clears, poll-reschedule races) are logged, not captured.
- **`workers/api/src/twist/entrypoint.ts` is a template literal** — do NOT edit it in a way that adds raw backticks (not touched by this plan; noted for safety).
- **Twister SDK changes** (`public/twister/src/**`) require a changeset in `public/.changeset/` (`minor`, first line `Added: …`) and land as a **separate `public/` PR**.
- **No DB schema migrations** — connector data flows through `integrations.save*`; `channel.link_types` already exists and syncs to the client.
- **UI copy is sentence case** (Flutter): "Add a comment", "Write a public LinkedIn post".
- **`dart:io Platform.isX` throws on web** — not used here, but any platform gate must be `kIsWeb`-guarded.

## Package names & test commands

- `libs/unipile` → `@plotday/unipile`; test: `pnpm --filter @plotday/unipile test <path>`; lint: `pnpm --filter @plotday/unipile lint`.
- `workers/api` → `@plotday/api`; test: `pnpm --filter @plotday/api test <path>`; lint: `pnpm --filter @plotday/api lint`.
- connector: `cd connectors/linkedin && npx tsc --noEmit` (type-check).
- Twister SDK: `cd public/twister && pnpm build`.
- Flutter: `cd apps/plot && flutter analyze`.

## File map (what each file is responsible for)

- `libs/unipile/src/linkedin-posts.ts` **(new)** — Plot-facing post/comment/reaction types, channel-id helpers, reaction-emoji maps, and pure builders (`buildPostLink`, `buildPostBodyNote`, `buildCommentNote`, `buildReactionsFromPostReactions`, `adaptivePollDelayMs`, `mapEmojiToPostReactionType`, `mapPostReactionTypeToEmoji`).
- `libs/unipile/src/linkedin-posts.test.ts` **(new)** — unit tests for the above.
- `libs/unipile/src/linkedin.ts` — add posts/comments/reactions abstract methods to `LinkedInMessaging`; re-export the new post types.
- `libs/unipile/src/index.ts` — export the new module.
- `workers/api/src/twist/tools/unipile/client.ts` — v2 `createPost`/`listOwnPosts`/`getPost`/`listComments`/`createComment`/`addPostReaction`/`removePostReaction`/`listPostReactions`.
- `workers/api/src/twist/tools/unipile/types.ts` — raw v2 post/comment/reaction response types.
- `workers/api/src/twist/tools/unipile/normalize.ts` — `normalizePost`/`normalizeComment`/`normalizePostReaction`.
- `workers/api/src/twist/tools/unipile/linkedin.ts` — implement the new tool methods (wrap client + `withAccount` + normalize).
- `workers/api/src/twist/tools/unipile/posts-client.test.ts` **(new)**, `normalize.test.ts` — tests.
- `connectors/linkedin/src/linkedin.ts` — channels, `post` link type, `onCreateLink`, `onNoteCreated`, `onNoteReactionChanged`, `discoverPosts`, `pollPostComments`.
- `public/twister/src/tools/integrations.ts` — `LinkTypeConfig.reactionCapabilities?`.
- `public/twister/src/connector.ts` — `CreateLinkDraft.attachments?`.
- `public/.changeset/linkedin-post-linktype-fields.md` **(new)**.
- `workers/api/src/app/sync/create-link-dispatch.ts` — populate `draft.attachments` from the first note's file actions.
- `apps/plot/lib/store/link.dart` — parse `reactionCapabilities` in `LinkTypeConfig.fromJson`.
- `apps/plot/lib/command/note.dart` — resolve reaction capabilities per link type.
- `apps/plot/lib/page/new_thread.dart`, `apps/plot/lib/widget/note_editor.dart` — allow attachments when composing a `post`.
- `docs/features.md`, `docs/updates.d/<slug>-<id>.md`.

---

# PHASE 1 — Core (channel, compose text post, post-as-thread, flat comments two-way, polling)

## Task 1.1: Plot-facing post types, channel-id helpers, reaction maps

**Files:**
- Create: `libs/unipile/src/linkedin-posts.ts`
- Create: `libs/unipile/src/linkedin-posts.test.ts`

**Interfaces:**
- Produces:
  - `type LinkedInPost = { id: string; text: string; createdAt: Date; author: ChatProfile; url: string | null }`
  - `type LinkedInComment = { id: string; text: string; createdAt: Date; author: ChatProfile; parentCommentId: string | null }`
  - `type LinkedInPostReaction = { reactorId: string; reactorName: string | null; reactorPictureUrl: string | null; reactionType: string }`
  - `type PostAttachment = { buffer: Uint8Array; filename: string; mimeType: string }`
  - `const POSTS_CHANNEL_SUFFIX = "#posts"`
  - `function postsChannelId(accountId: string): string`
  - `function accountIdFromChannel(channelId: string): string`
  - `const LINKEDIN_POST_REACTIONS: readonly string[]`
  - `function mapEmojiToPostReactionType(emoji: string): string | null`
  - `function mapPostReactionTypeToEmoji(type: string): string | null`

- [ ] **Step 1: Write the failing test**

Create `libs/unipile/src/linkedin-posts.test.ts`:

```ts
import { describe, expect, test } from "vitest";
import {
  POSTS_CHANNEL_SUFFIX,
  postsChannelId,
  accountIdFromChannel,
  LINKEDIN_POST_REACTIONS,
  mapEmojiToPostReactionType,
  mapPostReactionTypeToEmoji,
} from "./linkedin-posts";

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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm --filter @plotday/unipile test src/linkedin-posts.test.ts`
Expected: FAIL — cannot find module `./linkedin-posts`.

- [ ] **Step 3: Write minimal implementation**

Create `libs/unipile/src/linkedin-posts.ts` (helpers + maps only for now; builders added in 1.6):

```ts
import type { ChatProfile } from "./messaging";

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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm --filter @plotday/unipile test src/linkedin-posts.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add libs/unipile/src/linkedin-posts.ts libs/unipile/src/linkedin-posts.test.ts
git commit -m "feat(linkedin): post-channel types, id helpers, reaction maps"
```

---

## Task 1.2: Raw v2 types + normalizers for posts/comments/reactions

**Files:**
- Modify: `workers/api/src/twist/tools/unipile/types.ts` (append)
- Modify: `workers/api/src/twist/tools/unipile/normalize.ts`
- Modify: `workers/api/src/twist/tools/unipile/normalize.test.ts`

**Interfaces:**
- Consumes: `LinkedInPost`, `LinkedInComment`, `LinkedInPostReaction` (Task 1.1); `normalizeProfile` (existing).
- Produces:
  - `normalizePost(raw: UnipilePostRaw, provider: string): LinkedInPost`
  - `normalizeComment(raw: UnipileCommentRaw, provider: string): LinkedInComment`
  - `normalizePostReaction(raw: UnipilePostReactionRaw, provider: string): LinkedInPostReaction`

- [ ] **Step 1: Add raw types**

Append to `workers/api/src/twist/tools/unipile/types.ts` (permissive — v2 shapes are LIVE-CONFIRM; read multiple candidate fields):

```ts
// ---------- Posts / comments / reactions (v2, LIVE-CONFIRM shapes) ----------

/** A post returned by GET /v2/:acc/users/me/posts or GET /v2/:acc/posts/:id. */
export type UnipilePostRaw = {
  id?: string;
  /** urn:li:activity:… — the id all post interactions key on. */
  social_id?: string;
  share_url?: string;
  text?: string | null;
  date?: string;
  parsed_datetime?: string;
  author?: UnipileUser & { public_profile_url?: string };
};
export type UnipilePostListRaw = {
  object?: string;
  items?: UnipilePostRaw[];
  data?: UnipilePostRaw[];
  cursor?: string | null;
  next_cursor?: string | null;
};

/** A comment or reply on a post. */
export type UnipileCommentRaw = {
  id: string;
  text?: string | null;
  date?: string;
  parsed_datetime?: string;
  author?: UnipileUser & { public_profile_url?: string };
  /** Set on replies; identifies the top-level comment they hang under. */
  parent_comment_id?: string | null;
  parent?: string | null;
};
export type UnipileCommentListRaw = {
  object?: string;
  items?: UnipileCommentRaw[];
  data?: UnipileCommentRaw[];
  cursor?: string | null;
  next_cursor?: string | null;
};

/** Echo returned by POST .../posts (create post). */
export type UnipileCreatedPostRaw = {
  object?: string;
  post_id?: string;
  social_id?: string;
  id?: string;
};
/** Echo returned by POST .../posts/:id/comments (create comment). */
export type UnipileCreatedCommentRaw = {
  object?: string;
  comment_id?: string;
  id?: string;
};

/** A single reactor entry from GET .../posts/:id/reactions. */
export type UnipilePostReactionRaw = {
  value?: string;
  reaction_type?: string;
  author?: UnipileUser & { public_profile_url?: string };
};
export type UnipilePostReactionListRaw = {
  object?: string;
  items?: UnipilePostReactionRaw[];
  data?: UnipilePostReactionRaw[];
  cursor?: string | null;
  next_cursor?: string | null;
};
```

- [ ] **Step 2: Write the failing test**

Append to `workers/api/src/twist/tools/unipile/normalize.test.ts` (add the imports to the existing `import { … } from "./normalize"` line):

```ts
import { normalizePost, normalizeComment, normalizePostReaction } from "./normalize";

describe("normalizePost", () => {
  test("uses social_id as id and parses date", () => {
    const post = normalizePost(
      {
        social_id: "urn:li:activity:7",
        text: "Hello world",
        date: "2026-06-20T12:00:00Z",
        share_url: "https://www.linkedin.com/feed/update/urn:li:activity:7/",
        author: { id: "auth1", display_name: "Kris Braun", public_identifier: "krisbraun" },
      },
      "linkedin"
    );
    expect(post.id).toBe("urn:li:activity:7");
    expect(post.text).toBe("Hello world");
    expect(post.createdAt.toISOString()).toBe("2026-06-20T12:00:00.000Z");
    expect(post.author.name).toBe("Kris Braun");
    expect(post.url).toBe("https://www.linkedin.com/feed/update/urn:li:activity:7/");
  });
});

describe("normalizeComment", () => {
  test("top-level comment has null parent", () => {
    const c = normalizeComment(
      { id: "c1", text: "nice", date: "2026-06-20T12:05:00Z", author: { id: "u2", display_name: "Ada" } },
      "linkedin"
    );
    expect(c.id).toBe("c1");
    expect(c.parentCommentId).toBeNull();
    expect(c.author.name).toBe("Ada");
  });
  test("reply carries parent_comment_id", () => {
    const c = normalizeComment(
      { id: "c2", text: "thanks", parent_comment_id: "c1", author: { id: "u3", display_name: "Bo" } },
      "linkedin"
    );
    expect(c.parentCommentId).toBe("c1");
  });
});

describe("normalizePostReaction", () => {
  test("maps reactor + type", () => {
    const r = normalizePostReaction(
      { reaction_type: "like", author: { id: "u9", display_name: "Cy", public_picture_url: "http://x/y.jpg" } },
      "linkedin"
    );
    expect(r).toEqual({ reactorId: "u9", reactorName: "Cy", reactorPictureUrl: "http://x/y.jpg", reactionType: "like" });
  });
});
```

- [ ] **Step 3: Run test to verify it fails**

Run: `pnpm --filter @plotday/api test src/twist/tools/unipile/normalize.test.ts`
Expected: FAIL — `normalizePost` is not exported.

- [ ] **Step 4: Write the normalizers**

In `workers/api/src/twist/tools/unipile/normalize.ts`, extend the `import type { … } from "@plotday/unipile"` block with `LinkedInPost, LinkedInComment, LinkedInPostReaction`, extend the `./types` import with the new raw types, and append:

```ts
export function normalizePost(raw: UnipilePostRaw, provider: string): LinkedInPost {
  const id = raw.social_id ?? raw.id ?? "";
  const when = raw.date ?? raw.parsed_datetime;
  const author = raw.author
    ? normalizeProfile(raw.author, provider, true)
    : { id: "", isSelf: true, handle: null, name: "You", subtitle: null, email: null, phone: null, pictureUrl: null, profileUrl: null };
  return {
    id,
    text: raw.text ?? "",
    createdAt: when ? new Date(when) : new Date(0),
    author,
    url: raw.share_url ?? raw.author?.public_profile_url ?? null,
  };
}

export function normalizeComment(raw: UnipileCommentRaw, provider: string): LinkedInComment {
  const when = raw.date ?? raw.parsed_datetime;
  const author = raw.author
    ? normalizeProfile(raw.author, provider, false)
    : { id: "", isSelf: false, handle: null, name: "Unknown", subtitle: null, email: null, phone: null, pictureUrl: null, profileUrl: null };
  return {
    id: raw.id,
    text: raw.text ?? "",
    createdAt: when ? new Date(when) : new Date(0),
    author,
    parentCommentId: raw.parent_comment_id ?? raw.parent ?? null,
  };
}

export function normalizePostReaction(raw: UnipilePostReactionRaw, provider: string): LinkedInPostReaction {
  const a = raw.author;
  const profile = a ? normalizeProfile(a, provider, false) : null;
  return {
    reactorId: profile?.id ?? "",
    reactorName: profile?.name ?? null,
    reactorPictureUrl: profile?.pictureUrl ?? null,
    reactionType: raw.reaction_type ?? raw.value ?? "like",
  };
}
```

- [ ] **Step 5: Re-export the Plot-facing types from `@plotday/unipile`**

In `libs/unipile/src/index.ts`, add `export * from "./linkedin-posts";` so `LinkedInPost`/`LinkedInComment`/`LinkedInPostReaction`/`PostAttachment` resolve from `@plotday/unipile` (used by the normalize import). Run `pnpm --filter @plotday/unipile lint` to confirm the barrel compiles.

- [ ] **Step 6: Run tests to verify they pass**

Run: `pnpm --filter @plotday/api test src/twist/tools/unipile/normalize.test.ts`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add workers/api/src/twist/tools/unipile/types.ts \
        workers/api/src/twist/tools/unipile/normalize.ts \
        workers/api/src/twist/tools/unipile/normalize.test.ts \
        libs/unipile/src/index.ts
git commit -m "feat(linkedin): normalize v2 posts, comments, reactions"
```

---

## Task 1.3: v2 UnipileClient post/comment methods

**Files:**
- Modify: `workers/api/src/twist/tools/unipile/client.ts`
- Create: `workers/api/src/twist/tools/unipile/posts-client.test.ts`

**Interfaces:**
- Consumes: raw types (Task 1.2), the private `get`/`post`/`request`/`base`/`env`/`fetchImpl` members of `UnipileClient`.
- Produces on `UnipileClient`:
  - `createPost(input: { accountId; text; visibility?; attachments? }): Promise<UnipileCreatedPostRaw>`
  - `listOwnPosts(input: { accountId; cursor?; limit? }): Promise<UnipilePostListRaw>`
  - `getPost(input: { accountId; postId }): Promise<UnipilePostRaw>`
  - `listComments(input: { accountId; postId; cursor?; limit? }): Promise<UnipileCommentListRaw>`
  - `createComment(input: { accountId; postId; text; commentId?; attachments? }): Promise<UnipileCreatedCommentRaw>`
  - `addPostReaction(input: { accountId; socialId; reactionType }): Promise<void>`
  - `removePostReaction(input: { accountId; socialId }): Promise<void>`
  - `listPostReactions(input: { accountId; socialId; cursor?; limit? }): Promise<UnipilePostReactionListRaw>`

- [ ] **Step 1: Write the failing test**

Create `workers/api/src/twist/tools/unipile/posts-client.test.ts`:

```ts
import { describe, expect, test, vi } from "vitest";
import { UnipileClient } from "./client";

const env = { UNIPILE_API_KEY: "k", UNIPILE_WEBHOOK_SECRET: "s" };

function fakeFetch(status: number, body: unknown) {
  return vi.fn(async (_url: string, _init?: RequestInit) =>
    new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } })
  );
}

describe("UnipileClient posts (v2)", () => {
  test("createPost posts text to /v2/:acc/posts", async () => {
    const f = fakeFetch(200, { object: "PostCreated", social_id: "urn:li:activity:1" });
    const c = new UnipileClient(env, f as unknown as typeof fetch);
    const res = await c.createPost({ accountId: "acct", text: "hi" });
    expect(res.social_id).toBe("urn:li:activity:1");
    const [url, init] = f.mock.calls[0]!;
    expect(url).toBe("https://api.unipile.com/v2/acct/posts");
    expect(init!.method).toBe("POST");
    expect(JSON.parse(init!.body as string)).toMatchObject({ text: "hi", visibility: "public" });
  });

  test("listComments GETs the post's comments with account_id in the path", async () => {
    const f = fakeFetch(200, { items: [{ id: "c1", text: "yo" }], next_cursor: null });
    const c = new UnipileClient(env, f as unknown as typeof fetch);
    const res = await c.listComments({ accountId: "acct", postId: "urn:li:activity:1", limit: 50 });
    expect(res.items?.[0]?.id).toBe("c1");
    const [url] = f.mock.calls[0]!;
    expect(url).toContain("/v2/acct/posts/urn%3Ali%3Aactivity%3A1/comments");
    expect(url).toContain("limit=50");
  });

  test("createComment includes comment_id when replying", async () => {
    const f = fakeFetch(200, { comment_id: "c2" });
    const c = new UnipileClient(env, f as unknown as typeof fetch);
    await c.createComment({ accountId: "acct", postId: "p", text: "re", commentId: "c1" });
    const [, init] = f.mock.calls[0]!;
    expect(JSON.parse(init!.body as string)).toMatchObject({ text: "re", comment_id: "c1" });
  });

  test("addPostReaction posts reaction_type", async () => {
    const f = fakeFetch(200, {});
    const c = new UnipileClient(env, f as unknown as typeof fetch);
    await c.addPostReaction({ accountId: "acct", socialId: "p", reactionType: "like" });
    const [url, init] = f.mock.calls[0]!;
    expect(url).toContain("/v2/acct/posts/p/reactions");
    expect(JSON.parse(init!.body as string)).toMatchObject({ reaction_type: "like" });
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm --filter @plotday/api test src/twist/tools/unipile/posts-client.test.ts`
Expected: FAIL — `createPost` is not a function.

- [ ] **Step 3: Write the client methods**

Add to the `import type { … } from "./types"` block: `UnipileCreatedPostRaw, UnipilePostListRaw, UnipilePostRaw, UnipileCommentListRaw, UnipileCreatedCommentRaw, UnipilePostReactionListRaw`. Then add these methods to `UnipileClient` (after the LinkedIn relations block). All routes are **`LIVE-CONFIRM`**:

```ts
  // ---------- Posts / comments / reactions (v2, LIVE-CONFIRM) ----------

  /** Create a post. v1 is `POST /api/v1/posts` (account_id in body); v2 moves
   * account_id into the path. `attachments` are base64 JSON like message sends. */
  createPost(input: {
    accountId: string;
    text: string;
    visibility?: "public" | "connections";
    attachments?: Array<{ buffer: Uint8Array; filename: string; mimeType: string }>;
  }): Promise<UnipileCreatedPostRaw> {
    const attachments = (input.attachments ?? []).map((a) => ({
      filename: a.filename,
      content_type: a.mimeType,
      data: base64FromBytes(a.buffer),
    }));
    return this.post<UnipileCreatedPostRaw>(
      `/v2/${encodeURIComponent(input.accountId)}/posts`,
      {
        text: input.text,
        visibility: input.visibility ?? "public",
        ...(attachments.length > 0 ? { attachments } : {}),
      }
    );
  }

  /** The connected account's own posts. Mirrors users/me/relations paging. */
  listOwnPosts(input: {
    accountId: string;
    cursor?: string | null;
    limit?: number;
  }): Promise<UnipilePostListRaw> {
    return this.get<UnipilePostListRaw>(
      `/v2/${encodeURIComponent(input.accountId)}/users/me/posts`,
      {
        ...(input.limit ? { limit: String(input.limit) } : {}),
        ...(input.cursor ? { cursor: input.cursor } : {}),
      }
    );
  }

  getPost(input: { accountId: string; postId: string }): Promise<UnipilePostRaw> {
    return this.get<UnipilePostRaw>(
      `/v2/${encodeURIComponent(input.accountId)}/posts/${encodeURIComponent(input.postId)}`
    );
  }

  listComments(input: {
    accountId: string;
    postId: string;
    cursor?: string | null;
    limit?: number;
  }): Promise<UnipileCommentListRaw> {
    return this.get<UnipileCommentListRaw>(
      `/v2/${encodeURIComponent(input.accountId)}/posts/${encodeURIComponent(input.postId)}/comments`,
      {
        ...(input.limit ? { limit: String(input.limit) } : {}),
        ...(input.cursor ? { cursor: input.cursor } : {}),
      }
    );
  }

  /** Comment on a post. `commentId` nests the comment as a reply to that comment. */
  createComment(input: {
    accountId: string;
    postId: string;
    text: string;
    commentId?: string | null;
    attachments?: Array<{ buffer: Uint8Array; filename: string; mimeType: string }>;
  }): Promise<UnipileCreatedCommentRaw> {
    const attachments = (input.attachments ?? []).map((a) => ({
      filename: a.filename,
      content_type: a.mimeType,
      data: base64FromBytes(a.buffer),
    }));
    return this.post<UnipileCreatedCommentRaw>(
      `/v2/${encodeURIComponent(input.accountId)}/posts/${encodeURIComponent(input.postId)}/comments`,
      {
        text: input.text,
        ...(input.commentId ? { comment_id: input.commentId } : {}),
        ...(attachments.length > 0 ? { attachments } : {}),
      }
    );
  }

  async addPostReaction(input: {
    accountId: string;
    socialId: string;
    reactionType: string;
  }): Promise<void> {
    await this.post<unknown>(
      `/v2/${encodeURIComponent(input.accountId)}/posts/${encodeURIComponent(input.socialId)}/reactions`,
      { reaction_type: input.reactionType }
    );
  }

  /** Best-effort clear (mirrors removeMessageReaction: try empty, then DELETE). */
  async removePostReaction(input: { accountId: string; socialId: string }): Promise<void> {
    const path = `/v2/${encodeURIComponent(input.accountId)}/posts/${encodeURIComponent(input.socialId)}/reactions`;
    try {
      await this.post<unknown>(path, { reaction_type: "" });
      return;
    } catch (e) {
      if (!(e instanceof UnipileApiError) || (e.status !== 400 && e.status !== 404 && e.status !== 405)) throw e;
    }
    try {
      await this.request(path, { method: "DELETE" });
    } catch (e) {
      if (e instanceof UnipileApiError && (e.status === 404 || e.status === 405)) return;
      throw e;
    }
  }

  listPostReactions(input: {
    accountId: string;
    socialId: string;
    cursor?: string | null;
    limit?: number;
  }): Promise<UnipilePostReactionListRaw> {
    return this.get<UnipilePostReactionListRaw>(
      `/v2/${encodeURIComponent(input.accountId)}/posts/${encodeURIComponent(input.socialId)}/reactions`,
      {
        ...(input.limit ? { limit: String(input.limit) } : {}),
        ...(input.cursor ? { cursor: input.cursor } : {}),
      }
    );
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm --filter @plotday/api test src/twist/tools/unipile/posts-client.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/twist/tools/unipile/client.ts \
        workers/api/src/twist/tools/unipile/posts-client.test.ts
git commit -m "feat(linkedin): v2 client createPost/listComments/reactions (LIVE-CONFIRM)"
```

---

## Task 1.4: Surface post methods on the LinkedInMessaging tool

**Files:**
- Modify: `libs/unipile/src/linkedin.ts` (abstract methods)
- Modify: `workers/api/src/twist/tools/unipile/linkedin.ts` (impl)

**Interfaces:**
- Consumes: `UnipileClient` post methods (Task 1.3); `normalizePost`/`normalizeComment`/`normalizePostReaction` (Task 1.2); `accountIdFromChannel` (Task 1.1); `withAccount` (existing base).
- Produces on `LinkedInMessaging` (both abstract + concrete). `channelId` is the **Public Post channel id** (`accountId#posts`); the impl strips it for the URL and asserts auth against it.
  - `createPost(params: { channelId; text; attachments? }): Promise<{ postId: string }>`
  - `listOwnPosts(params: { channelId; cursor?; limit? }): Promise<{ posts: LinkedInPost[]; nextCursor: string | null }>`
  - `getPost(params: { channelId; postId }): Promise<LinkedInPost | null>`
  - `listComments(params: { channelId; postId; cursor?; limit? }): Promise<{ comments: LinkedInComment[]; nextCursor: string | null }>`
  - `createComment(params: { channelId; postId; text; parentCommentId?; attachments? }): Promise<{ commentId: string }>`
  - `reactToPost(params: { channelId; socialId; reactionType }): Promise<void>`
  - `unreactToPost(params: { channelId; socialId }): Promise<void>`
  - `listPostReactions(params: { channelId; socialId; cursor?; limit? }): Promise<{ reactions: LinkedInPostReaction[]; nextCursor: string | null }>`

- [ ] **Step 1: Add abstract methods**

In `libs/unipile/src/linkedin.ts`, import the post types and add abstract methods to `LinkedInMessaging`:

```ts
import type {
  LinkedInComment,
  LinkedInPost,
  LinkedInPostReaction,
  PostAttachment,
} from "./linkedin-posts";

// …inside class LinkedInMessaging, after ignoreInvitation:

  abstract createPost(params: {
    channelId: string;
    text: string;
    attachments?: PostAttachment[];
  }): Promise<{ postId: string }>;

  abstract listOwnPosts(params: {
    channelId: string;
    cursor?: string | null;
    limit?: number;
  }): Promise<{ posts: LinkedInPost[]; nextCursor: string | null }>;

  abstract getPost(params: {
    channelId: string;
    postId: string;
  }): Promise<LinkedInPost | null>;

  abstract listComments(params: {
    channelId: string;
    postId: string;
    cursor?: string | null;
    limit?: number;
  }): Promise<{ comments: LinkedInComment[]; nextCursor: string | null }>;

  abstract createComment(params: {
    channelId: string;
    postId: string;
    text: string;
    parentCommentId?: string | null;
    attachments?: PostAttachment[];
  }): Promise<{ commentId: string }>;

  abstract reactToPost(params: {
    channelId: string;
    socialId: string;
    reactionType: string;
  }): Promise<void>;

  abstract unreactToPost(params: {
    channelId: string;
    socialId: string;
  }): Promise<void>;

  abstract listPostReactions(params: {
    channelId: string;
    socialId: string;
    cursor?: string | null;
    limit?: number;
  }): Promise<{ reactions: LinkedInPostReaction[]; nextCursor: string | null }>;
```

(`// eslint-disable-next-line @typescript-eslint/no-unused-vars` above each, matching the existing invitation/relation abstracts.)

- [ ] **Step 2: Rebuild the SDK barrel so the impl can import**

Run: `pnpm --filter @plotday/unipile lint`
Expected: PASS (types compile).

- [ ] **Step 3: Implement on the tool**

In `workers/api/src/twist/tools/unipile/linkedin.ts`, extend imports and add the methods. Note `accountIdFromChannel` recovers the raw Unipile account id; `withAccount(params.channelId)` asserts the Public Post channel's config + token:

```ts
import { accountIdFromChannel } from "@plotday/unipile";
import { normalizeComment, normalizePost, normalizePostReaction } from "./normalize";

// …inside class LinkedInMessaging:

  async createPost(params: { channelId: string; text: string; attachments?: PostAttachment[] }): Promise<{ postId: string }> {
    return this.withAccount(params.channelId, async () => {
      const acc = accountIdFromChannel(params.channelId);
      const res = await this.client.createPost({ accountId: acc, text: params.text, visibility: "public", attachments: params.attachments });
      const postId = res.social_id ?? res.post_id ?? res.id ?? "";
      return { postId };
    });
  }

  async listOwnPosts(params: { channelId: string; cursor?: string | null; limit?: number }): Promise<{ posts: LinkedInPost[]; nextCursor: string | null }> {
    return this.withAccount(params.channelId, async () => {
      const acc = accountIdFromChannel(params.channelId);
      const res = await this.client.listOwnPosts({ accountId: acc, cursor: params.cursor ?? null, limit: params.limit });
      const rows = res.items ?? res.data ?? [];
      return { posts: rows.map((p) => normalizePost(p, this.provider)), nextCursor: res.next_cursor ?? res.cursor ?? null };
    });
  }

  async getPost(params: { channelId: string; postId: string }): Promise<LinkedInPost | null> {
    return this.withAccount(params.channelId, async () => {
      const acc = accountIdFromChannel(params.channelId);
      try {
        const raw = await this.client.getPost({ accountId: acc, postId: params.postId });
        return normalizePost(raw, this.provider);
      } catch (e) {
        if (e instanceof UnipileApiError && e.status === 404) return null;
        throw e;
      }
    });
  }

  async listComments(params: { channelId: string; postId: string; cursor?: string | null; limit?: number }): Promise<{ comments: LinkedInComment[]; nextCursor: string | null }> {
    return this.withAccount(params.channelId, async () => {
      const acc = accountIdFromChannel(params.channelId);
      const res = await this.client.listComments({ accountId: acc, postId: params.postId, cursor: params.cursor ?? null, limit: params.limit });
      const rows = res.items ?? res.data ?? [];
      return { comments: rows.map((c) => normalizeComment(c, this.provider)), nextCursor: res.next_cursor ?? res.cursor ?? null };
    });
  }

  async createComment(params: { channelId: string; postId: string; text: string; parentCommentId?: string | null; attachments?: PostAttachment[] }): Promise<{ commentId: string }> {
    return this.withAccount(params.channelId, async () => {
      const acc = accountIdFromChannel(params.channelId);
      const res = await this.client.createComment({ accountId: acc, postId: params.postId, text: params.text, commentId: params.parentCommentId ?? null, attachments: params.attachments });
      return { commentId: res.comment_id ?? res.id ?? "" };
    });
  }

  async reactToPost(params: { channelId: string; socialId: string; reactionType: string }): Promise<void> {
    return this.withAccount(params.channelId, () =>
      this.client.addPostReaction({ accountId: accountIdFromChannel(params.channelId), socialId: params.socialId, reactionType: params.reactionType })
    );
  }

  async unreactToPost(params: { channelId: string; socialId: string }): Promise<void> {
    return this.withAccount(params.channelId, () =>
      this.client.removePostReaction({ accountId: accountIdFromChannel(params.channelId), socialId: params.socialId })
    );
  }

  async listPostReactions(params: { channelId: string; socialId: string; cursor?: string | null; limit?: number }): Promise<{ reactions: LinkedInPostReaction[]; nextCursor: string | null }> {
    return this.withAccount(params.channelId, async () => {
      const acc = accountIdFromChannel(params.channelId);
      const res = await this.client.listPostReactions({ accountId: acc, socialId: params.socialId, cursor: params.cursor ?? null, limit: params.limit });
      const rows = res.items ?? res.data ?? [];
      return { reactions: rows.map((r) => normalizePostReaction(r, this.provider)), nextCursor: res.next_cursor ?? res.cursor ?? null };
    });
  }
```

Add the imports `UnipileApiError` (already imported in messaging base — import from `./client` here) and the `LinkedInPost`/`LinkedInComment`/`LinkedInPostReaction`/`PostAttachment` types from `@plotday/unipile` at the top of the file.

- [ ] **Step 4: Type-check both packages**

Run: `pnpm --filter @plotday/unipile lint && pnpm --filter @plotday/api lint`
Expected: PASS (no `abstract method not implemented` errors — the impl now satisfies the abstract surface).

- [ ] **Step 5: Commit**

```bash
git add libs/unipile/src/linkedin.ts workers/api/src/twist/tools/unipile/linkedin.ts
git commit -m "feat(linkedin): posts/comments/reactions on LinkedInMessaging tool"
```

---

## Task 1.5: Pure builders — post link, post-body note, comment note

**Files:**
- Modify: `libs/unipile/src/linkedin-posts.ts`
- Modify: `libs/unipile/src/linkedin-posts.test.ts`

**Interfaces:**
- Consumes: `profileToContact` (from `./connector-helpers`); `LinkedInPost`/`LinkedInComment`/`LinkedInPostReaction` (Task 1.1).
- Produces:
  - `function postThreadSource(postId: string): string` → `linkedin:post:${postId}`
  - `function postBodyNoteKey(postId: string): string` → `post-${postId}`
  - `function commentNoteKey(commentId: string): string` → `comment-${commentId}`
  - `function buildReactionsFromPostReactions(reactions: LinkedInPostReaction[], cap?: number): NewReactions | undefined`
  - `function buildPostBodyNote(post: LinkedInPost, reactions?: LinkedInPostReaction[]): NewNote`
  - `function buildCommentNote(postId: string, comment: LinkedInComment, reactions?: LinkedInPostReaction[]): NewNote`
  - `function buildPostLink(opts: { accountId; channelId; post: LinkedInPost; comments: LinkedInComment[]; postReactions?: LinkedInPostReaction[]; commentReactions?: Map<string, LinkedInPostReaction[]>; initialSync: boolean }): NewLinkWithNotes`

- [ ] **Step 1: Write the failing test**

Append to `libs/unipile/src/linkedin-posts.test.ts`:

```ts
import {
  postThreadSource, postBodyNoteKey, commentNoteKey,
  buildPostBodyNote, buildCommentNote, buildPostLink,
} from "./linkedin-posts";
import type { LinkedInPost, LinkedInComment } from "./linkedin-posts";
import type { ChatProfile } from "./messaging";

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
    const n = buildPostBodyNote(post);
    expect(n.key).toBe("post-urn:li:activity:7");
    expect(n.content).toBe("Shipping today!");
    expect((n.thread as { source: string }).source).toBe("linkedin:post:urn:li:activity:7");
    expect(n.author?.name).toBe("Kris");
    expect(n.reNote).toBeUndefined();
  });
});

describe("buildCommentNote", () => {
  test("top-level comment has no reNote", () => {
    const c: LinkedInComment = { id: "c1", text: "nice", createdAt: new Date("2026-06-20T12:05:00Z"), author: prof({ id: "u2", name: "Ada" }), parentCommentId: null };
    const n = buildCommentNote(post.id, c);
    expect(n.key).toBe("comment-c1");
    expect(n.reNote).toBeUndefined();
    expect(n.author?.name).toBe("Ada");
  });
  test("reply sets reNote to the parent comment key", () => {
    const c: LinkedInComment = { id: "c2", text: "ty", createdAt: new Date(), author: prof({ id: "u3", name: "Bo" }), parentCommentId: "c1" };
    const n = buildCommentNote(post.id, c);
    expect(n.reNote).toEqual({ key: "comment-c1" });
  });
});

describe("buildPostLink", () => {
  test("assembles thread with body note first, then comments", () => {
    const comments: LinkedInComment[] = [
      { id: "c1", text: "nice", createdAt: new Date("2026-06-20T12:05:00Z"), author: prof({ id: "u2", name: "Ada" }), parentCommentId: null },
    ];
    const link = buildPostLink({ accountId: "acct", channelId: "acct#posts", post, comments, initialSync: true });
    expect(link.source).toBe("linkedin:post:urn:li:activity:7");
    expect(link.type).toBe("post");
    expect(link.meta).toMatchObject({ syncProvider: "linkedin", accountId: "acct", channelId: "acct#posts", postId: "urn:li:activity:7" });
    expect(link.notes?.[0]?.key).toBe("post-urn:li:activity:7");
    expect(link.notes?.[1]?.key).toBe("comment-c1");
    expect(link.unread).toBe(false); // initialSync
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm --filter @plotday/unipile test src/linkedin-posts.test.ts`
Expected: FAIL — builders not exported.

- [ ] **Step 3: Write the builders**

Append to `libs/unipile/src/linkedin-posts.ts`:

```ts
import { ActionType } from "@plotday/twister/plot";
import type { NewActor, NewNote, NewReactions } from "@plotday/twister/plot";
import type { NewLinkWithNotes } from "@plotday/twister";
import { profileToContact } from "./connector-helpers";

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
  };
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
  };
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm --filter @plotday/unipile test src/linkedin-posts.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add libs/unipile/src/linkedin-posts.ts libs/unipile/src/linkedin-posts.test.ts
git commit -m "feat(linkedin): pure builders for post link + comment/body notes"
```

---

## Task 1.6: Adaptive poll-delay helper

**Files:**
- Modify: `libs/unipile/src/linkedin-posts.ts`
- Modify: `libs/unipile/src/linkedin-posts.test.ts`

**Interfaces:**
- Produces: `function adaptivePollDelayMs(postCreatedAt: Date, now: Date): number | null` — base tier delay in ms, or `null` to retire (>30d). Caller adds jitter.

- [ ] **Step 1: Write the failing test**

Append to `libs/unipile/src/linkedin-posts.test.ts`:

```ts
import { adaptivePollDelayMs } from "./linkedin-posts";

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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm --filter @plotday/unipile test src/linkedin-posts.test.ts`
Expected: FAIL — `adaptivePollDelayMs` not exported.

- [ ] **Step 3: Write the implementation**

Append to `libs/unipile/src/linkedin-posts.ts`:

```ts
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm --filter @plotday/unipile test src/linkedin-posts.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add libs/unipile/src/linkedin-posts.ts libs/unipile/src/linkedin-posts.test.ts
git commit -m "feat(linkedin): adaptive comment-poll delay tiers"
```

---

## Task 1.7: Connector — two channels + `post` link type + enable/disable

**Files:**
- Modify: `connectors/linkedin/src/linkedin.ts`

**Interfaces:**
- Consumes: `postsChannelId`, `accountIdFromChannel`, `LINKEDIN_POST_REACTIONS`, `buildPostLink`, `adaptivePollDelayMs` (Tasks 1.1/1.5/1.6); tool methods (Task 1.4).
- Produces: connector state keys `posts_enabled_${channelId}` (marker that the Public Post channel is live), `post_poll_${postId}` (`{ createdAt: number; retireAfter: number }`), `known_post_${postId}` (dedup marker); scheduled callbacks `discoverPosts(channelId)`, `pollPostComments(channelId, postId)`.

> No connector unit-test harness exists in this repo (connectors are validated by `tsc --noEmit` + the tested `libs/unipile` helpers they call). Each connector task therefore ends with a type-check, not a vitest run.

- [ ] **Step 1: Add imports and the post link type**

At the top of `connectors/linkedin/src/linkedin.ts`, extend the `@plotday/unipile` import with:

```ts
import {
  accountIdFromChannel,
  adaptivePollDelayMs,
  buildCommentNote,
  buildPostLink,
  commentNoteKey,
  LINKEDIN_POST_REACTIONS,
  type LinkedInComment,
  type LinkedInPost,
  postBodyNoteKey,
  postsChannelId,
} from "@plotday/unipile";
```

> Later phases extend this import: Task 3.3 adds `mapEmojiToPostReactionType`; Task 3.4 adds `buildReactionsFromPostReactions` and `type LinkedInPostReaction`.

Add constants near the existing `TYPE_CONVERSATION`:

```ts
const TYPE_POST = "post";
// Number of comments/reactions fetched per poll page.
const COMMENT_PAGE_LIMIT = 50;
// Discovery poll cadence for natively-created posts (jittered).
const DISCOVER_MIN_MS = 60 * 60 * 1000;      // 1h
const DISCOVER_MAX_MS = 2 * 60 * 60 * 1000;  // 2h
// Initial import + discovery look-back window.
const IMPORT_WINDOW_MS = 7 * 24 * 60 * 60 * 1000;   // past week (initial)
const DISCOVER_WINDOW_MS = 30 * 24 * 60 * 60 * 1000; // 30 days (ongoing)
```

- [ ] **Step 2: Add the `post` link type to the class**

Add a `postLinkType` config the connector reuses for the Public Post channel (place it as a `private static readonly` on the class or a module const):

```ts
const POST_LINK_TYPE = {
  type: TYPE_POST,
  label: "Post",
  sourceName: "LinkedIn",
  sharingModel: "thread" as const, // personal view of the user's own post
  noteLabel: "Comment",
  replyPlaceholder: "Add a comment",
  replyVerb: "Comment",
  composePlaceholder: "Write a public LinkedIn post",
  composeVerb: "Post",
  supportsFileAttachments: true,
  reactionCapabilities: { mode: "fixed" as const, allowed: LINKEDIN_POST_REACTIONS },
  logo: "https://api.iconify.design/logos/linkedin-icon.svg",
  logoMono: "https://api.iconify.design/simple-icons/linkedin.svg",
  compose: { targets: "channels" as const },
};
```

> `sharingModel: "thread"` is used rather than `"channel"` so the single-participant (self) roster the connector sets is respected; there is no external membership to derive.

- [ ] **Step 3: Remove `singleChannel` and return two channels**

Delete the `readonly singleChannel = true;` line. Replace `getChannels`:

```ts
  async getChannels(
    auth: Authorization | null,
    token: AuthToken | null
  ): Promise<Channel[]> {
    if (!token?.token) return [];
    const accountId = token.token;
    const name = auth?.actor.name ?? "LinkedIn";
    return [
      // Messages: unchanged id (accountId) + connector-level `conversation` type.
      { id: accountId, title: name },
      // Public Post: opt-in, its own `post` link type.
      {
        id: postsChannelId(accountId),
        title: "Public Post",
        enabledByDefault: false,
        linkTypes: [POST_LINK_TYPE],
      },
    ];
  }
```

- [ ] **Step 4: Branch `onChannelEnabled` / `onChannelDisabled`**

At the top of `onChannelEnabled`, branch on the posts channel; keep the existing messaging body for the Messages channel:

```ts
  async onChannelEnabled(channel: Channel): Promise<void> {
    if (channel.id.endsWith("#posts")) {
      await this.onPostChannelEnabled(channel.id);
      return;
    }
    // …existing messaging body unchanged…
  }
```

Add the posts enable/disable handlers (import `channelSyncCompleted` via the existing `this.tools.integrations`):

```ts
  private async onPostChannelEnabled(channelId: string): Promise<void> {
    await this.set(`posts_enabled_${channelId}`, true);

    // Initial import: the past week of the account's own posts, with comments.
    const cutoff = Date.now() - IMPORT_WINDOW_MS;
    let cursor: string | null = null;
    const recentPostIds: string[] = [];
    for (let page = 0; page < 10; page++) {
      const { posts, nextCursor } = await this.tools.linkedin.listOwnPosts({ channelId, cursor, limit: 20 });
      let reachedOld = false;
      for (const post of posts) {
        if (post.createdAt.getTime() < cutoff) { reachedOld = true; continue; }
        await this.importPost(channelId, post, true);
        recentPostIds.push(post.id);
      }
      cursor = nextCursor;
      if (!cursor || reachedOld) break;
    }

    await this.tools.integrations.channelSyncCompleted(channelId);

    // Kick off each imported post's comment poll, then the discovery loop.
    for (const postId of recentPostIds) {
      const t = await this.callback(this.pollPostComments, channelId, postId);
      await this.runTask(t);
    }
    const discover = await this.callback(this.discoverPosts, channelId);
    await this.runTask(discover, { runAt: new Date(Date.now() + DISCOVER_MIN_MS) });
  }

  async onChannelDisabled(channel: Channel): Promise<void> {
    if (channel.id.endsWith("#posts")) {
      await this.clear(`posts_enabled_${channel.id}`);
      return;
    }
    // …existing messaging body unchanged…
  }
```

- [ ] **Step 5: Add `importPost` (fetch comments + save the link)**

```ts
  /** Fetch a post's comments and save it as a thread. `known_post_${id}` marks
   * it discovered so the discovery loop doesn't re-import. */
  private async importPost(channelId: string, post: LinkedInPost, initialSync: boolean): Promise<void> {
    const accountId = accountIdFromChannel(channelId);
    const comments = await this.fetchAllComments(channelId, post.id);
    const link = buildPostLink({ accountId, channelId, post, comments, initialSync });
    await this.tools.integrations.saveLinks([link]);
    await this.set(`known_post_${post.id}`, { createdAt: post.createdAt.getTime() });
  }

  private async fetchAllComments(channelId: string, postId: string): Promise<LinkedInComment[]> {
    const out: LinkedInComment[] = [];
    let cursor: string | null = null;
    for (let page = 0; page < 20; page++) {
      const { comments, nextCursor } = await this.tools.linkedin.listComments({ channelId, postId, cursor, limit: COMMENT_PAGE_LIMIT });
      out.push(...comments);
      cursor = nextCursor;
      if (!cursor) break;
    }
    return out;
  }
```

- [ ] **Step 6: Type-check**

Run: `cd connectors/linkedin && npx tsc --noEmit`
Expected: PASS (the poll methods `discoverPosts`/`pollPostComments` are added in Task 1.8 — if referenced before adding, add empty stubs `async discoverPosts(){}` / `async pollPostComments(){}` now and fill in 1.8, keeping this step green).

- [ ] **Step 7: Commit**

```bash
git add connectors/linkedin/src/linkedin.ts
git commit -m "feat(linkedin): Public Post channel + post link type + initial import"
```

---

## Task 1.8: Connector — discovery poll + adaptive comment poll

**Files:**
- Modify: `connectors/linkedin/src/linkedin.ts`

**Interfaces:**
- Consumes: `importPost`/`fetchAllComments` (Task 1.7); `adaptivePollDelayMs`, `buildCommentNote`, `commentNoteKey` (Tasks 1.5/1.6); tool `listComments`.
- Produces: `discoverPosts(channelId)`, `pollPostComments(channelId, postId)` (replaces the 1.7 stubs).

- [ ] **Step 1: Implement discovery**

```ts
  /** Find natively-created posts (Unipile has no post webhook) and import any
   * not already known. Reschedules itself on a 1–2h jitter while enabled. */
  async discoverPosts(channelId: string): Promise<void> {
    if (!(await this.get(`posts_enabled_${channelId}`))) return; // channel disabled → stop
    try {
      const cutoff = Date.now() - DISCOVER_WINDOW_MS;
      let cursor: string | null = null;
      const newPostIds: string[] = [];
      for (let page = 0; page < 10; page++) {
        const { posts, nextCursor } = await this.tools.linkedin.listOwnPosts({ channelId, cursor, limit: 20 });
        let reachedOld = false;
        for (const post of posts) {
          if (post.createdAt.getTime() < cutoff) { reachedOld = true; continue; }
          if (await this.get(`known_post_${post.id}`)) continue;
          await this.importPost(channelId, post, false);
          newPostIds.push(post.id);
        }
        cursor = nextCursor;
        if (!cursor || reachedOld) break;
      }
      for (const postId of newPostIds) {
        const t = await this.callback(this.pollPostComments, channelId, postId);
        await this.runTask(t);
      }
    } catch (error) {
      console.warn(`LinkedIn post discovery failed for ${channelId}`, error);
    }
    // Reschedule regardless (unless disabled, checked at top of next run).
    const delay = DISCOVER_MIN_MS + Math.random() * (DISCOVER_MAX_MS - DISCOVER_MIN_MS);
    const next = await this.callback(this.discoverPosts, channelId);
    await this.runTask(next, { runAt: new Date(Date.now() + delay) });
  }
```

- [ ] **Step 2: Implement the adaptive comment poll**

```ts
  /** Poll one post's comments, upsert new ones, and reschedule by post age.
   * Retires (no reschedule) once the post is >30 days old. */
  async pollPostComments(channelId: string, postId: string): Promise<void> {
    if (!(await this.get(`posts_enabled_${channelId}`))) return; // channel disabled → stop

    const known = await this.get<{ createdAt: number }>(`known_post_${postId}`);
    const createdAt = known ? new Date(known.createdAt) : new Date();

    try {
      const comments = await this.fetchAllComments(channelId, postId);
      if (comments.length > 0) {
        const notes = comments.map((c) => buildCommentNote(postId, c));
        await this.tools.integrations.saveLinks([
          {
            source: `linkedin:post:${postId}`,
            sources: [`linkedin:post:${postId}`],
            type: TYPE_POST,
            channelId,
            meta: { syncProvider: PROVIDER_KEY, accountId: accountIdFromChannel(channelId), channelId, postId },
            notes,
          },
        ]);
      }
    } catch (error) {
      console.warn(`LinkedIn comment poll failed for post ${postId}`, error);
    }

    const delay = adaptivePollDelayMs(createdAt, new Date());
    if (delay === null) return; // retire
    const jittered = delay + Math.random() * delay * 0.2;
    const next = await this.callback(this.pollPostComments, channelId, postId);
    await this.runTask(next, { runAt: new Date(Date.now() + jittered) });
  }
```

> `saveLinks` upserts by `source`; re-saving the same post with only new comment notes merges them (existing notes dedupe by `key`). This mirrors how the messaging webhook re-saves a chat link with new messages.

- [ ] **Step 3: Type-check**

Run: `cd connectors/linkedin && npx tsc --noEmit`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add connectors/linkedin/src/linkedin.ts
git commit -m "feat(linkedin): discovery poll + adaptive comment poll"
```

---

## Task 1.9: Connector — `onCreateLink` for posts + `onNoteCreated` top-level comment

**Files:**
- Modify: `connectors/linkedin/src/linkedin.ts`

**Interfaces:**
- Consumes: tool `createPost`/`createComment`; `postBodyNoteKey` (Task 1.5); `markdownToPlainText` (existing import).
- Produces: `post`-type branches in `onCreateLink` and `onNoteCreated`.

- [ ] **Step 1: Extend `onCreateLink`**

At the top of `onCreateLink`, before the `conversation` handling, add:

```ts
    if (draft.type === TYPE_POST) {
      const text = markdownToPlainText((draft.noteContent ?? draft.title ?? "").trim());
      if (!text) {
        console.error("[linkedin] onCreateLink(post): empty body; cannot post.");
        return null;
      }
      const channelId = draft.channelId;
      const { postId } = await this.tools.linkedin.createPost({ channelId, text });
      if (!postId) {
        console.error("[linkedin] onCreateLink(post): no post id returned.");
        return null;
      }
      const accountId = accountIdFromChannel(channelId);
      await this.set(`known_post_${postId}`, { createdAt: Date.now() });
      // Start this post's comment poll.
      const t = await this.callback(this.pollPostComments, channelId, postId);
      await this.runTask(t, { runAt: new Date(Date.now() + 5 * 60 * 1000) });
      return {
        source: `linkedin:post:${postId}`,
        sources: [`linkedin:post:${postId}`],
        type: TYPE_POST,
        title: draft.title,
        created: new Date(),
        channelId,
        meta: { syncProvider: PROVIDER_KEY, accountId, channelId, postId },
      } satisfies NewLinkWithNotes;
    }
```

> The composed thread already carries the user's first note (the post body) in Plot; `onCreateLink` returns the link only. Attachments on compose are added in Phase 4.

- [ ] **Step 2: Extend `onNoteCreated` for post threads (top-level comment)**

At the top of `onNoteCreated`, before the existing `chatId` handling, add:

```ts
    const meta0 = (thread.meta ?? {}) as Record<string, unknown>;
    const postId = meta0.postId as string | undefined;
    if (postId) {
      const channelId = meta0.channelId as string | undefined;
      if (!channelId) return;
      // The post body note is authored via onCreateLink's returned link, not a
      // reply — skip it so we don't comment our own post text.
      if (note.key === postBodyNoteKey(postId)) return;
      const text = markdownToPlainText(note.content ?? "");
      if (!text) return;
      const { commentId } = await this.tools.linkedin.createComment({ channelId, postId, text });
      return { key: `comment-${commentId}`, externalContent: text };
    }
```

> Nested-reply routing (`reNoteKey`) and comment attachments are added in Phases 2 and 4. For Phase 1 every Plot reply is a top-level comment.

- [ ] **Step 3: Type-check**

Run: `cd connectors/linkedin && npx tsc --noEmit`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add connectors/linkedin/src/linkedin.ts
git commit -m "feat(linkedin): compose post + write-back top-level comments"
```

---

## Task 1.10: Phase 1 docs

**Files:**
- Modify: `docs/features.md`
- Create: `docs/updates.d/<slug>-<id>.md` (via `pnpm updates:new`)

- [ ] **Step 1: Add the update fragment**

Run: `pnpm updates:new "LinkedIn public posts"` and edit the created file so it reads:

```markdown
### LinkedIn

- Post to LinkedIn straight from Plot and follow the conversation — comments on your posts show up as replies, and replying in Plot comments back on LinkedIn.
```

- [ ] **Step 2: Update features.md**

Add a bullet under the LinkedIn/connectors section of `docs/features.md`:

```markdown
- LinkedIn Public Post channel: compose a public LinkedIn post from Plot; comments sync two-way.
```

- [ ] **Step 3: Commit**

```bash
git add docs/features.md docs/updates.d/
git commit -m "docs(linkedin): public post channel update fragment + features"
```

**Phase 1 gate:** `pnpm --filter @plotday/unipile test && pnpm --filter @plotday/api test && pnpm --filter @plotday/unipile lint && pnpm --filter @plotday/api lint && (cd connectors/linkedin && npx tsc --noEmit)` all pass. Phase 1 is independently shippable: a Public Post channel that composes text posts and syncs comments two-way (flat, top-level).

---

# PHASE 2 — Nested comment replies

## Task 2.1: Outbound nested replies via `reNoteKey`

**Files:**
- Modify: `connectors/linkedin/src/linkedin.ts`

**Interfaces:**
- Consumes: `thread.meta.reNoteKey` (runtime-provided, `integrations.ts:2383`); `commentNoteKey`/`postBodyNoteKey` (Task 1.5).

- [ ] **Step 1: Route the reply target**

Replace the Phase-1 `onNoteCreated` post branch's `createComment` call so it resolves nesting from `reNoteKey`:

```ts
    if (postId) {
      const channelId = meta0.channelId as string | undefined;
      if (!channelId) return;
      if (note.key === postBodyNoteKey(postId)) return;
      const text = markdownToPlainText(note.content ?? "");
      if (!text) return;

      // reNoteKey (runtime-resolved) is the key of the note this reply targets.
      // A comment key → nested reply; the post-body key or absent → top-level.
      const reNoteKey = meta0.reNoteKey as string | undefined;
      let parentCommentId: string | null = null;
      if (reNoteKey && reNoteKey.startsWith("comment-")) {
        parentCommentId = reNoteKey.slice("comment-".length);
      }

      const { commentId } = await this.tools.linkedin.createComment({
        channelId, postId, text, parentCommentId,
      });
      return { key: `comment-${commentId}`, externalContent: text };
    }
```

- [ ] **Step 2: Type-check**

Run: `cd connectors/linkedin && npx tsc --noEmit`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add connectors/linkedin/src/linkedin.ts
git commit -m "feat(linkedin): reply-to-comment posts a nested LinkedIn reply"
```

> Inbound nesting already works: `buildCommentNote` (Task 1.5) sets `reNote: { key: comment-<parentId> }` for replies, and `fetchAllComments` returns replies with `parentCommentId`. Confirm `listComments` returns replies (not only top-level) during `LIVE-CONFIRM`; if replies need a separate fetch per comment, extend `fetchAllComments` to page `listComments` per top-level comment id.

---

# PHASE 3 — Reactions two-way

## Task 3.1: Twister SDK — per-link-type reaction capabilities (public submodule)

**Files:**
- Modify: `public/twister/src/tools/integrations.ts`
- Create: `public/.changeset/linkedin-post-linktype-fields.md`

**Interfaces:**
- Produces: `LinkTypeConfig.reactionCapabilities?: ReactionCapabilities`.

- [ ] **Step 1: Add the field**

In `public/twister/src/tools/integrations.ts`, import/reference the existing `ReactionCapabilities` type (from `../connector` — check the export path) and add to `LinkTypeConfig`:

```ts
  /**
   * Per-link-type reaction capabilities. Overrides the connector-level
   * {@link Connector.reactionCapabilities} for threads of this link type — used
   * when one connector has link types with different reaction vocabularies
   * (e.g. LinkedIn DMs' 7-emoji set vs. posts' fixed post-reaction set). Omit to
   * inherit the connector-level value.
   */
  reactionCapabilities?: ReactionCapabilities;
```

- [ ] **Step 2: Add the changeset**

Create `public/.changeset/linkedin-post-linktype-fields.md`:

```markdown
---
"@plotday/twister": minor
---

Added: `LinkTypeConfig.reactionCapabilities` for per-link-type reaction pickers.
```

- [ ] **Step 3: Build + validate**

Run: `cd public/twister && pnpm build` then `cd public && pnpm validate-changesets`
Expected: build succeeds; changeset validates.

- [ ] **Step 4: Refresh the workspace link + commit (in the submodule)**

```bash
cd public && git add twister/src/tools/integrations.ts .changeset/linkedin-post-linktype-fields.md && git commit -m "feat(twister): LinkTypeConfig.reactionCapabilities" && cd ..
pnpm install
```

> The `public/` commit lands as its own PR; the parent repo records the submodule bump at the end of the feature.

---

## Task 3.2: Flutter — parse + resolve per-link-type reaction capabilities

**Files:**
- Modify: `apps/plot/lib/store/link.dart`
- Modify: `apps/plot/lib/store/channel.dart`
- Modify: `apps/plot/lib/command/note.dart`

**Interfaces:**
- Consumes: `LinkTypeConfig` (Dart), `reactionCapabilitiesFromJson` (`apps/plot/lib/store/reaction.dart`), `Channel.parsedLinkTypes` + static `_cache` (`apps/plot/lib/store/channel.dart`), `Thread.primaryLink` (`thread.dart:4928`).

- [ ] **Step 1: Parse the field in `LinkTypeConfig`**

In `apps/plot/lib/store/link.dart`, add a field to `LinkTypeConfig` and its `fromJson`:

```dart
  final Map<String, dynamic>? reactionCapabilities;
```
```dart
      reactionCapabilities:
          json['reactionCapabilities'] as Map<String, dynamic>? ??
          json['reaction_capabilities'] as Map<String, dynamic>?,
```
Add `this.reactionCapabilities,` to the const constructor.

- [ ] **Step 2: Add a `_cache`-scan resolver to `channel.dart`**

The DM `conversation` and post `post` link types live on *different* channels of the same connection, so resolve by scanning that connection's cached channels for the one whose `parsedLinkTypes` declares the thread's link type. Add to `apps/plot/lib/store/channel.dart` (uses the existing static `_cache` and `parsedLinkTypes`; keyed `${twistInstanceId}:${channelId}`, matching `findBySource`):

```dart
  /// Reaction capabilities declared for [type] on any of [ptId]'s channels, or
  /// null when none declares them (caller falls back to the connection-level
  /// value).
  static Map<String, dynamic>? reactionCapabilitiesFor(Uuid ptId, String type) {
    final prefix = '${ptId.toString()}:';
    for (final entry in _cache.entries) {
      if (!entry.key.startsWith(prefix)) continue;
      for (final lt in entry.value.parsedLinkTypes ?? const <LinkTypeConfig>[]) {
        if (lt.type == type && lt.reactionCapabilities != null) {
          return lt.reactionCapabilities;
        }
      }
    }
    return null;
  }
```

- [ ] **Step 3: Prefer per-link-type caps in `note.dart`**

In `apps/plot/lib/command/note.dart` `run`, after computing `connectionId` and `instance` (existing lines ~315-319), resolve the primary link's type and prefer its caps:

```dart
      final primary = Thread.primaryLink(links);
      final perTypeCaps = (connectionId == null || primary?.type == null)
          ? null
          : Channel.reactionCapabilitiesFor(connectionId, primary!.type!);
      final caps = reactionCapabilitiesFromJson(
        perTypeCaps ?? instance?.reactionCapabilities,
      );
```

(`connectionId` is `Thread.primaryLink(links)?.createdBy` — already computed at `note.dart:315`; `Link.type` and `Link.createdBy` are the verified getters at `link.dart:584`/`581`.)

- [ ] **Step 4: Analyze**

Run: `cd apps/plot && flutter analyze`
Expected: no new errors.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/store/link.dart apps/plot/lib/store/channel.dart apps/plot/lib/command/note.dart
git commit -m "feat(app): resolve reaction picker per link type"
```

> Manual check (run-app skill): open a LinkedIn post thread and a LinkedIn DM thread; the reaction picker offers the post set (👍❤️👏💡😂🤝) on the post and the DM set on the DM.

---

## Task 3.3: Connector — outbound reactions on posts/comments

**Files:**
- Modify: `connectors/linkedin/src/linkedin.ts`

**Interfaces:**
- Consumes: tool `reactToPost`/`unreactToPost`; `mapEmojiToPostReactionType`, `LINKEDIN_POST_REACTIONS` (Task 1.1); `reconcilePerUserReaction` (existing helper).

- [ ] **Step 1: Branch `onNoteReactionChanged` for post threads**

At the top of `onNoteReactionChanged`, before the existing chat handling:

```ts
    const pmeta = (thread.meta ?? {}) as Record<string, unknown>;
    const postId = pmeta.postId as string | undefined;
    if (postId) {
      const channelId = pmeta.channelId as string | undefined;
      if (!channelId) return;
      // socialId: the comment id for a comment note, else the post id.
      const socialId = note.key && note.key.startsWith("comment-")
        ? note.key.slice("comment-".length)
        : postId;

      const stateKey = `post_reaction_sent:${socialId}`;
      const lastSent = (await this.get<string>(stateKey)) ?? null;
      const decision = reconcilePerUserReaction(lastSent, emoji, added, LINKEDIN_POST_REACTIONS);
      if (decision.action === "none") return;
      try {
        if (decision.action === "set") {
          const reactionType = mapEmojiToPostReactionType(decision.emoji);
          if (!reactionType) return;
          await this.tools.linkedin.reactToPost({ channelId, socialId, reactionType });
          await this.set(stateKey, decision.emoji);
        } else {
          await this.tools.linkedin.unreactToPost({ channelId, socialId });
          await this.clear(stateKey);
        }
      } catch (error) {
        console.warn(`LinkedIn post reaction write-back failed for ${socialId}`, error);
      }
      return;
    }
```

- [ ] **Step 2: Type-check**

Run: `cd connectors/linkedin && npx tsc --noEmit`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add connectors/linkedin/src/linkedin.ts
git commit -m "feat(linkedin): write back post/comment reactions per user"
```

---

## Task 3.4: Connector — inbound reactions in the comment poll (bounded)

**Files:**
- Modify: `connectors/linkedin/src/linkedin.ts`

**Interfaces:**
- Consumes: tool `listPostReactions`; `buildCommentNote`/`buildReactionsFromPostReactions`/`postBodyNoteKey` (Task 1.5).
- Extend the connector's `@plotday/unipile` import with `buildReactionsFromPostReactions` and `type LinkedInPostReaction`.

Key idea: emit **reaction-only** notes on upsert. A note with `key` + `reactions` but **no `content` field** merges its reactions onto the existing note without touching its text (upsert dedupes by `key`). So the post body's reactions attach via a content-less note keyed `post-<id>`, and comments already carry both content and reactions.

- [ ] **Step 1: Add the bounded reaction fetch helper**

```ts
  /** Fetch up to 50 reactors for a post or comment. Bounded so a viral post
   * can't materialize thousands of contacts. Best-effort — returns [] on error. */
  private async fetchReactions(channelId: string, socialId: string): Promise<LinkedInPostReaction[]> {
    try {
      const { reactions } = await this.tools.linkedin.listPostReactions({ channelId, socialId, limit: 50 });
      return reactions;
    } catch (error) {
      console.warn(`LinkedIn reaction fetch failed for ${socialId}`, error);
      return [];
    }
  }
```

- [ ] **Step 2: Reflect reactions in `pollPostComments`**

In `pollPostComments`, replace the comment-notes assembly (Task 1.8 Step 2) with one that also fetches reactions and adds a content-less body-reaction note:

```ts
      const comments = await this.fetchAllComments(channelId, postId);
      const postReactions = await this.fetchReactions(channelId, postId);

      const notes: import("@plotday/twister/plot").NewNote[] = [];
      const bodyReactions = buildReactionsFromPostReactions(postReactions);
      if (bodyReactions) {
        // No `content` → upsert leaves the post body text untouched, only merges reactions.
        notes.push({ thread: { source: `linkedin:post:${postId}` }, key: postBodyNoteKey(postId), reactions: bodyReactions });
      }
      for (const c of comments) {
        const cr = await this.fetchReactions(channelId, c.id);
        notes.push(buildCommentNote(postId, c, cr));
      }

      if (notes.length > 0) {
        await this.tools.integrations.saveLinks([{
          source: `linkedin:post:${postId}`,
          sources: [`linkedin:post:${postId}`],
          type: TYPE_POST,
          channelId,
          meta: { syncProvider: PROVIDER_KEY, accountId: accountIdFromChannel(channelId), channelId, postId },
          notes,
        }]);
      }
```

- [ ] **Step 3: Type-check**

Run: `cd connectors/linkedin && npx tsc --noEmit`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add connectors/linkedin/src/linkedin.ts
git commit -m "feat(linkedin): reflect inbound post/comment reactions (bounded)"
```

---

# PHASE 4 — Attachments / images

## Task 4.1: Comment attachments (reply with a file)

**Files:**
- Modify: `connectors/linkedin/src/linkedin.ts`

**Interfaces:**
- Consumes: `note.actions` file actions (existing pattern in `onNoteCreated`'s DM path); tool `createComment` `attachments`.

- [ ] **Step 1: Read file actions and pass to `createComment`**

In the `onNoteCreated` post branch (Task 2.1), before `createComment`, extract attachments exactly as the DM path does:

```ts
      const fileActions = (note.actions ?? []).filter(
        (a): a is Extract<Action, { type: typeof ActionType.file }> => a.type === ActionType.file
      );
      const attachments: Array<{ buffer: Uint8Array; filename: string; mimeType: string }> = [];
      for (const action of fileActions) {
        try {
          const file = await this.tools.files.read(action.fileId);
          attachments.push({ buffer: file.data, filename: file.fileName, mimeType: file.mimeType });
        } catch (e) {
          console.error("LinkedIn comment attachment read failed", action.fileId, e);
        }
      }
      const { commentId } = await this.tools.linkedin.createComment({
        channelId, postId, text, parentCommentId,
        attachments: attachments.length > 0 ? attachments : undefined,
      });
      return { key: `comment-${commentId}`, externalContent: text };
```

- [ ] **Step 2: Type-check + commit**

Run: `cd connectors/linkedin && npx tsc --noEmit`

```bash
git add connectors/linkedin/src/linkedin.ts
git commit -m "feat(linkedin): attach files when commenting on a post"
```

---

## Task 4.2: Twister SDK — `CreateLinkDraft.attachments` (public submodule)

**Files:**
- Modify: `public/twister/src/connector.ts`
- Modify: `public/.changeset/linkedin-post-linktype-fields.md` (append to the existing changeset summary)

**Interfaces:**
- Produces: `CreateLinkDraft.attachments?: Array<{ fileId: string; fileName: string; mimeType: string; fileSize: number | null }>`.

- [ ] **Step 1: Add the field**

In `public/twister/src/connector.ts`, add to `CreateLinkDraft`:

```ts
  /**
   * File actions on the composed thread's first note, for link types whose
   * compose creates media (e.g. a LinkedIn post with an image). Empty/undefined
   * when the composer attached no files. Read the bytes via the Files tool.
   */
  attachments?: Array<{ fileId: string; fileName: string; mimeType: string; fileSize: number | null }>;
```

- [ ] **Step 2: Update the changeset summary line**

Make `public/.changeset/linkedin-post-linktype-fields.md` read:

```markdown
Added: `LinkTypeConfig.reactionCapabilities` and `CreateLinkDraft.attachments`.
```

- [ ] **Step 3: Build, validate, commit (submodule) + refresh link**

```bash
cd public/twister && pnpm build && cd .. && pnpm validate-changesets
git add twister/src/connector.ts .changeset/linkedin-post-linktype-fields.md && git commit -m "feat(twister): CreateLinkDraft.attachments" && cd ..
pnpm install
```

---

## Task 4.3: Runtime — populate `draft.attachments` from the first note

**Files:**
- Modify: `workers/api/src/app/sync/create-link-dispatch.ts`

**Interfaces:**
- Consumes: the composed thread's first-note `actions` (file actions); the `DraftForConnector` shape (`create-link-dispatch.ts:26-34`).

- [ ] **Step 1: Add `attachments` to the draft type + populate it**

In `create-link-dispatch.ts`, add `attachments?` to the draft type mirroring the SDK field, then when building the draft, map the first note's file actions:

```ts
  attachments: (firstNote?.actions ?? [])
    .filter((a) => a.type === "file")
    .map((a) => ({ fileId: a.fileId, fileName: a.fileName, mimeType: a.mimeType, fileSize: a.fileSize ?? null })),
```

(Locate `firstNote` where `noteContent` is derived — the same note supplies both. If the file mirrors the `noteContent` from a passed-in note object, read its `actions` there.)

- [ ] **Step 2: Type-check + test**

Run: `pnpm --filter @plotday/api lint && pnpm --filter @plotday/api test src/app/sync`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add workers/api/src/app/sync/create-link-dispatch.ts
git commit -m "feat(api): carry composed first-note attachments into create_link draft"
```

---

## Task 4.4: Connector — attach image when composing a post

**Files:**
- Modify: `connectors/linkedin/src/linkedin.ts`

**Interfaces:**
- Consumes: `draft.attachments` (Task 4.2); tool `createPost` `attachments`.

- [ ] **Step 1: Read draft attachments in `onCreateLink(post)`**

In the `TYPE_POST` branch of `onCreateLink` (Task 1.9), before `createPost`:

```ts
      const attachments: Array<{ buffer: Uint8Array; filename: string; mimeType: string }> = [];
      for (const a of draft.attachments ?? []) {
        try {
          const file = await this.tools.files.read(a.fileId);
          attachments.push({ buffer: file.data, filename: file.fileName, mimeType: file.mimeType });
        } catch (e) {
          console.error("LinkedIn post attachment read failed", a.fileId, e);
        }
      }
      const { postId } = await this.tools.linkedin.createPost({
        channelId, text, attachments: attachments.length > 0 ? attachments : undefined,
      });
```

- [ ] **Step 2: Type-check + commit**

Run: `cd connectors/linkedin && npx tsc --noEmit`

```bash
git add connectors/linkedin/src/linkedin.ts
git commit -m "feat(linkedin): attach images to composed posts"
```

---

## Task 4.5: Flutter — allow attachments when composing a `post`

**Files:**
- Modify: `apps/plot/lib/page/new_thread.dart`
- Modify: `apps/plot/lib/widget/note_editor.dart` (if the compose editor reuses the note editor)

**Interfaces:**
- Consumes: `LinkTypeConfig.supportsFileAttachments` (already parsed, `link.dart:76`).

- [ ] **Step 1: Gate the compose attach button on the target link type**

In the new-thread composer, where the target link type is known, show the attach affordance when `linkType?.supportsFileAttachments == true` (mirror `note_editor.dart:1470`'s `_canAttachFile`). Ensure attached files become `file` actions on the first note so the runtime (Task 4.3) forwards them.

```dart
    final canAttach = targetLinkType?.supportsFileAttachments ?? false;
    // …render the attach button only when canAttach…
```

- [ ] **Step 2: Analyze**

Run: `cd apps/plot && flutter analyze`
Expected: no new errors.

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/page/new_thread.dart apps/plot/lib/widget/note_editor.dart
git commit -m "feat(app): attach images when composing a LinkedIn post"
```

> Manual check (run-app + tunnel skills): compose a post with an image; confirm it appears on LinkedIn; comment with an attachment; confirm the file uploads.

---

## Task 4.6: Finalize

- [ ] **Step 1: Run `/finalize`** — lint all changed packages, verify error capture (`captureException` in new catch blocks handling unexpected errors), confirm the update fragment exists, and open the `public/` submodule PR + record the submodule bump in this repo.
- [ ] **Step 2: Full test sweep**

Run:
```bash
pnpm --filter @plotday/unipile test && pnpm --filter @plotday/unipile lint && \
pnpm --filter @plotday/api test && pnpm --filter @plotday/api lint && \
(cd connectors/linkedin && npx tsc --noEmit) && \
(cd apps/plot && flutter analyze)
```
Expected: all pass.

- [ ] **Step 3: `LIVE-CONFIRM` sweep** — against the live v2 API (dev workspace), verify: `POST /v2/:acc/posts` body/visibility field, `GET /v2/:acc/users/me/posts` shape + cursor field, `GET/POST /v2/:acc/posts/:id/comments` (including whether replies come inline or need per-comment paging), reaction `reaction_type` enum strings, and the create echoes' id field names. Adjust the normalizers/client defensively where reality differs; remove `LIVE-CONFIRM` markers once verified.

---

## Self-review notes

- **Spec coverage:** channel model (1.7), compose→post (1.9/4.4), post-as-thread + past-week import (1.7), discovery poll (1.8), adaptive comment poll (1.8), flat comments two-way (1.9), nested replies in/out (1.5 build + 2.1), reactions two-way + per-link-type picker (1.1/3.1–3.4), attachments comments+posts (4.1–4.5), v2 client (1.3), tool (1.4), normalize (1.2), SDK additions (3.1/4.2), runtime draft (4.3), docs (1.10), no schema migrations, error capture, LIVE-CONFIRM (4.6). All spec sections map to a task.
- **Known LIVE-CONFIRM risks called out:** exact v2 routes, reaction enum, whether `listComments` returns replies inline (Task 2.1 note gives the fallback), and the `createPost` visibility field.
- **Type consistency:** `channelId` on tool methods = Public Post channel id throughout; `accountIdFromChannel` strips it in the tool impl and connector; note keys `post-<id>`/`comment-<id>` are produced by `postBodyNoteKey`/`commentNoteKey` and consumed identically in `onNoteCreated`/`onNoteReactionChanged`.
