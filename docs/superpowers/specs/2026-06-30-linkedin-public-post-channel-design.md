# LinkedIn "Public Post" channel — design spec

**Date:** 2026-06-30
**Status:** Approved (design). Ready for implementation planning.
**Scope:** Add a second channel — **Public Post** — to the private LinkedIn
connector. Composing to it creates a public LinkedIn post. Each post (created in
Plot *or* natively on LinkedIn) becomes a Plot thread; comments sync **both
ways** with full fidelity: nested replies, reactions, and attachments/images.

---

## 1. Summary & goals

The LinkedIn connector today is messaging-only (`singleChannel = true`, one DM
inbox channel, link type `conversation`). This feature adds a **Public Post**
channel exposing a new `post` link type:

- **Compose → post:** writing a new thread to the Public Post channel creates a
  public LinkedIn post via Unipile.
- **Post as thread:** every post is a Plot thread; the post body is the first
  note; comments are notes.
- **Comments two-way:** inbound comments become notes; a reply in Plot posts a
  comment back to LinkedIn.
- **Nested replies:** Plot's "reply to note" on a comment creates a *nested*
  LinkedIn comment (reply to that specific comment); a plain thread reply creates
  a top-level comment.
- **Reactions two-way:** react in Plot → react on LinkedIn (post or comment);
  inbound reactions reflect back as Plot note reactions. LinkedIn's post/comment
  reaction set differs from the DM set, so the reaction picker becomes
  per-link-type.
- **Attachments/images:** compose a post with an image; reply to a post with an
  attachment.

### Sync scope (confirmed with product)

- **Initial sync** (when the channel is enabled): import the **past 7 days** of
  the connected account's own posts as threads, with their existing comments.
- **Ongoing:** sync **both** Plot-created and natively-LinkedIn-created posts.
  Plot-created posts are known at `onCreateLink`; native posts are found by a
  recurring **discovery poll** (Unipile has no post webhook).

### Non-goals

- Editing/deleting posts from Plot.
- Reposts / shares, external-link cards, mentions in composed posts (future).
- Syncing comments on **other people's** posts (only the connected account's own
  posts are threads).

---

## 2. Key platform facts (why the design is shaped this way)

- **Unipile supports posts & comments** (verified against developer.unipile.com):
  create post, list a user's own posts, get a post, list comments, create a
  comment (with `comment_id` for nested replies), add/list reactions.
- **No post/comment webhook.** Unipile's webhooks are messaging-only
  (`account.connected`, `account.needs_reauth`, `messaging.new_message`,
  `users.invitation.received`, `users.new_relation` — see
  `workers/api/src/app/hook-messaging.ts`). Therefore **inbound comments,
  inbound reactions, and discovery of native posts are all polled**.
- **The existing `UnipileClient` is v2-only** (`https://api.unipile.com/v2`,
  `account_id` in the path). Public docs show v1 paths (`/api/v1/posts`); the
  established convention (used for chats/relations/invitations) is to translate
  v1 → v2 by moving `account_id` into the path and marking the exact route
  `LIVE-CONFIRM` until verified against the live v2 API. **All new calls use
  v2.**
- **`reNote` is Plot's reply-to-note mechanism** (`public/twister/src/plot.ts`):
  `Note.reNote = { id } | null` (read), `NewNote.reNote = { id } | { key } |
  null` (write). The runtime already resolves a replied-to note's **key** into
  `thread.meta.reNoteKey` on connector dispatch
  (`workers/api/src/twist/tools/integrations.ts:2375-2385`) — so the outbound
  nested-reply path needs no runtime change.
- **Link-type configs are already synced to the Flutter client**
  (`apps/plot/lib/store/channel.dart` → `parsedLinkTypes` →
  `LinkTypeConfig.fromJson` in `apps/plot/lib/store/link.dart`). Adding a
  per-link-type field (reaction capabilities) is a localized change.
- **Reaction capabilities are currently resolved per twist-instance**, not per
  link type (`apps/plot/lib/command/note.dart:319` reads
  `instance.reactionCapabilities`). That resolver already has the thread's
  primary link in hand (`note.dart:315`), so per-link-type resolution is a small
  change.

---

## 3. Channel & link-type model

### 3.1 Two channels

- Remove `singleChannel = true` from the connector (it now has two channels; the
  UI shows a channel list instead of inline config).
- `getChannels()` returns:
  - **Messages** — `id = token.token` (unchanged), link type `conversation`.
    Title stays the account name (display-only; avoids disturbing existing
    installs).
  - **Public Post** — `id = `​`` `${token.token}#posts` ``, `enabledByDefault:
    false` (opt-in), carrying its own `linkTypes: [post]` (per-channel override,
    so the DM channel keeps only `conversation`).

### 3.2 Channel-id ↔ account-id mapping

Both channels are backed by the same Unipile account (same token). The posts
channel id has a `#posts` suffix, so introduce a helper:

```ts
const POSTS_CHANNEL_SUFFIX = "#posts";
const postsChannelId = (accountId: string) => `${accountId}${POSTS_CHANNEL_SUFFIX}`;
const accountIdFromChannel = (channelId: string) =>
  channelId.endsWith(POSTS_CHANNEL_SUFFIX)
    ? channelId.slice(0, -POSTS_CHANNEL_SUFFIX.length)
    : channelId;
```

Every post link also stashes `meta.accountId` (the raw Unipile account id) so
write-back paths (`onNoteCreated`, `onNoteReactionChanged`) never re-parse the
channel id. Post-flow methods read `meta.accountId`; existing message-flow
methods keep reading `meta.channelId` — clean separation, no collision.

Webhook-callback registration (`createFromParent(this.onWebhookEvent, ...)`) is
**only** done for the Messages channel; posts don't use webhooks.

### 3.3 `post` link-type config

```ts
{
  type: "post",
  label: "Post",
  sourceName: "LinkedIn",
  sharingModel: "channel",           // public audience; no per-thread roster editor
  noteLabel: "Comment",
  replyPlaceholder: "Add a comment",
  replyVerb: "Comment",
  composePlaceholder: "Write a public LinkedIn post",
  composeVerb: "Post",
  supportsFileAttachments: true,     // enables comment + post-compose attach button
  reactionCapabilities: { mode: "fixed", allowed: LINKEDIN_POST_REACTIONS },
  compose: { targets: "channels" },  // destination = the channel; a public post has no recipients
  logo:     "https://api.iconify.design/logos/linkedin-icon.svg",
  logoMono: "https://api.iconify.design/simple-icons/linkedin.svg",
}
```

---

## 4. Data model: keys, meta, threads/notes

- **Thread source:** `linkedin:post:${socialId}` (socialId = `urn:li:activity:…`).
- **Thread meta:** `{ syncProvider: "linkedin", accountId, channelId: postsChannelId, postId: socialId }`.
- **Post body note key:** `post-${socialId}` (authored by the connected user's own contact).
- **Comment note key:** `comment-${commentId}`.
  - Top-level comment: no `reNote` (attached to the thread).
  - Reply to a comment: `reNote: { key: "comment-${parentCommentId}" }`.
- **Comment/post authors** resolved via the existing `profileToContact` helper
  (so avatars/names render). The connected user's own posts/comments are
  attributed to their own contact (from `auth.actor` / `getOwnProfile`).
- **Thread roster (`accessContacts`):** `[connected user's own contact]` — the
  post is a personal view; only the connecting user sees it in Plot. Commenters
  are note authors, not roster members.

---

## 5. Compose → create post (`onCreateLink`, `draft.type === "post"`)

1. `text = markdownToPlainText(draft.noteContent ?? draft.title)` (LinkedIn posts
   are plain text).
2. Read `draft.attachments` (new SDK field — see §8), `files.read` each, collect
   `{ buffer, filename, mimeType }`.
3. `createPost({ accountId, text, visibility: "public", attachments })` → returns
   the post `social_id`.
4. Return a `NewLinkWithNotes`:
   - `source: linkedin:post:${socialId}`, `type: "post"`,
     `channelId: postsChannelId(accountId)`,
   - first note = the post body (key `post-${socialId}`, authored by own
     contact),
   - `meta: { syncProvider, accountId, channelId, postId: socialId }`.
5. Schedule this post's adaptive comment poll at tier-0 ("just published").

---

## 6. Sync-in (polling)

Two scheduled loops, built on the existing `this.callback(...)` +
`this.runTask(...)` pattern (mirrors `syncRelationsPage`), each bailing if the
channel was disabled (guard on a stored channel-enabled flag).

### 6.1 Initial import (`onChannelEnabled` for the Public Post channel)

- `listOwnPosts({ accountId })`, keep posts created within the **last 7 days**.
- For each, save the post thread (+ existing comments as notes, +reactions).
- Seed per-post poll state and schedule each post's comment poll.
- `channelSyncCompleted(channelId)`.

### 6.2 Discovery poll (`discoverPosts`, recurring ~1–2h jittered)

- `listOwnPosts({ accountId })`, look back ~30 days.
- For any post not already tracked (`known_posts_${channelId}` set / per-post
  state existence), create the thread and start its comment poll. This is how
  natively-created LinkedIn posts appear.

### 6.3 Adaptive per-post comment poll (`pollPostComments`)

- `listComments({ accountId, postId })` → upsert new comments as notes
  (`comment-${id}`, `reNote` for replies, author via `profileToContact`).
- Also fetch reactions for the post + comments (see §7 inbound).
- Reschedule by post age (each tier jittered ±):
  - `<1h`: ~5 min · `1–24h`: ~30 min · `1–7d`: ~3h · `7–30d`: daily · `>30d`: retire.
- State `post_poll_${postId}`: `{ createdAt, lastActivityAt, lastPolledAt,
  seenCommentIds / cursor }`.

### 6.4 Disable (`onChannelDisabled` for the Public Post channel)

- Clear channel-enabled flag, discovery state, and per-post poll state.
  Scheduled tasks check the flag and bail.

---

## 7. Comments & reactions — two-way detail

### 7.1 Outbound comment (`onNoteCreated`, post threads)

Branch on `meta.postId`:

- `text = markdownToPlainText(note.content)`.
- Extract file actions from `note.actions` (reuse the existing DM attachment
  path) → attachments.
- Determine nesting from `thread.meta.reNoteKey`:
  - `comment-${parentId}` → `commentOnPost({ accountId, postId, text, commentId:
    parentId, attachments })` (nested reply).
  - post-body key `post-${postId}` or absent → top-level comment.
- Return `{ key: "comment-${newCommentId}", externalContent: text }` so the poll
  echo dedupes onto the same note.

### 7.2 Reactions — vocabulary

```ts
// LinkedIn post/comment reactions (fixed). Emoji → Unipile reaction_type (LIVE-CONFIRM strings):
//   👍 like · 👏 celebrate · 🤝 support · ❤️ love · 💡 insightful · 😂 funny
const LINKEDIN_POST_REACTIONS = ["👍", "❤️", "👏", "💡", "😂", "🤝"] as const;
```

DMs keep the existing 7-set (`LINKEDIN_REACTIONS`); the two sets differ (posts
add 🤝, drop 😮/😢), which is why reaction capabilities must be per-link-type.

### 7.3 Outbound reaction (`onNoteReactionChanged`, post threads)

- Branch on `meta.postId`. `socialId` = post id (post-body note) or comment id
  (comment note, from `note.key`).
- Map emoji → reaction_type; `reactOnPost({ accountId, socialId, reactionType })`
  (or clear). Runs per-user (dispatched on the user's own instance, like DM
  reactions). Track last-sent in state for reconcile, mirroring the DM path.

### 7.4 Inbound reactions

- During the adaptive poll, `listReactions` for the post and each comment;
  reflect as Plot note reactions (reactors → `profileToContact`).
- **Bounded:** cap materialized reactor contacts per note (~50) so a viral post
  can't spawn thousands of contacts; `console.warn` when capped.

---

## 8. Cross-surface SDK & app extensions (additive)

### 8.1 Twister SDK (`public/twister`) — separate PR + changeset(s)

1. **`LinkTypeConfig.reactionCapabilities?: ReactionCapabilities`**
   (`public/twister/src/tools/integrations.ts`). Per-link-type override of the
   connector-level value.
2. **`CreateLinkDraft.attachments?`** (`public/twister/src/connector.ts`) —
   file-action refs from the composed thread's first note.

Both optional → fully backwards-compatible. Each change needs a changeset under
`public/.changeset/` (`minor`, `Added:` prefix) per repo rules.

### 8.2 API runtime (`workers/api`)

- `workers/api/src/app/sync/create-link-dispatch.ts`: include the composed
  thread's first-note file actions in the dispatched draft (`attachments`).

### 8.3 Flutter app (`apps/plot`)

- `apps/plot/lib/store/link.dart`: parse `reactionCapabilities` in
  `LinkTypeConfig.fromJson`.
- `apps/plot/lib/command/note.dart`: resolve reaction capabilities from the
  thread's **primary link type's** config first, falling back to
  `instance.reactionCapabilities`.
- `apps/plot/lib/page/new_thread.dart` (+ `apps/plot/lib/widget/note_editor.dart`):
  allow attaching files when composing a `post` new thread (honor
  `supportsFileAttachments`).

---

## 9. Unipile client & tool additions (v2, `LIVE-CONFIRM`)

`UnipileClient` (`workers/api/src/twist/tools/unipile/client.ts`) — all
`/v2/:accountId/...`, `account_id` in path:

| Method | v2 route (by convention; LIVE-CONFIRM) | Notes |
|---|---|---|
| `createPost` | `POST /v2/:accountId/posts` | body `{ text, visibility, attachments? }` |
| `listOwnPosts` | `GET /v2/:accountId/users/me/posts` | cursor-paged (mirrors `users/me/relations`) |
| `getPost` | `GET /v2/:accountId/posts/:postId` | |
| `listComments` | `GET /v2/:accountId/posts/:postId/comments` | cursor-paged; includes replies + parent id |
| `commentOnPost` | `POST /v2/:accountId/posts/:postId/comments` | body `{ text, comment_id?, attachments? }` |
| `reactOnPost` | `POST /v2/:accountId/posts/:socialId/reactions` | body `{ reaction_type }`; clear per DM pattern |
| `listReactions` | `GET /v2/:accountId/posts/:socialId/reactions` | cursor-paged |

- Surface these on the existing **`LinkedInMessaging`** tool (abstract in
  `libs/unipile/src/linkedin.ts`, impl in
  `workers/api/src/twist/tools/unipile/linkedin.ts`) — LinkedIn-only, no new
  factory wiring.
- New types in `workers/api/src/twist/tools/unipile/types.ts`
  (`UnipilePost`, `UnipileComment`, `UnipileReaction`, list + created echoes) and
  normalizers in `.../normalize.ts` (`normalizePost`, `normalizeComment`,
  `normalizeReaction`).

---

## 10. Build order (single spec, phased implementation)

1. **Core** — Public Post channel + `singleChannel` removal + channel/account-id
   mapping; `post` link type; `createPost` (text); post-as-thread; flat comments
   two-way; adaptive comment poll + discovery poll; past-week initial import.
2. **Nested replies** — inbound `reNote` wiring + outbound `reNoteKey` mapping
   (connector-only; runtime already supports it).
3. **Reactions** — SDK `LinkTypeConfig.reactionCapabilities` + Flutter
   resolution + connector outbound `onNoteReactionChanged` + inbound reaction
   poll (bounded).
4. **Attachments** — comment attachments (reuse existing note-actions path),
   then post-compose images (SDK `CreateLinkDraft.attachments` + runtime draft
   plumbing + composer).

---

## 11. Files touched

**Private connector** — `connectors/linkedin/src/linkedin.ts` (channels, link
type, `onCreateLink`, `onNoteCreated`, `onNoteReactionChanged`, poll methods,
constants).
**Unipile lib/tool** — `libs/unipile/src/linkedin.ts` (+types);
`workers/api/src/twist/tools/unipile/{linkedin,client,types,normalize}.ts`.
**Twister SDK (public submodule)** —
`public/twister/src/tools/integrations.ts`,
`public/twister/src/connector.ts`, + `public/.changeset/*`.
**API runtime** — `workers/api/src/app/sync/create-link-dispatch.ts`.
**Flutter app** — `apps/plot/lib/store/link.dart`,
`apps/plot/lib/command/note.dart`, `apps/plot/lib/page/new_thread.dart`,
`apps/plot/lib/widget/note_editor.dart`.
**Docs** — `docs/features.md`, `docs/updates.d/<slug>-<id>.md`.

---

## 12. Compatibility, error handling, testing

- **Additive & backwards-compatible.** New SDK fields are optional; existing
  connectors and older app clients are unaffected (older clients fall back to
  instance-level reaction caps and hide the post-compose attach button). **No DB
  schema migrations** — connector data flows through `integrations.save*`, and
  `channel.link_types` already exists.
- **Error handling.** All new `catch` blocks for unexpected errors call
  `tracker.captureException` / `postHog.captureException`
  (workers) per repo rules. Poll-scheduling failures rethrow so the runtime's
  task-retry machinery handles them (mirror `syncRelationsPage`). Expected
  failures (rate limits, best-effort reaction clears) are swallowed/logged, not
  captured.
- **Rate limits.** LinkedIn throttles hard; the client's 429 backoff applies.
  Adaptive polling and the ~30-day discovery window keep API volume bounded;
  inbound reaction materialization is capped.
- **Testing.** Unit tests for `normalizePost`/`normalizeComment`/
  `normalizeReaction` and the v2 client routes (extend
  `workers/api/src/twist/tools/unipile/*.test.ts`); connector-level tests for
  `onCreateLink` (post), `onNoteCreated` (top-level vs nested comment via
  `reNoteKey`), and `onNoteReactionChanged` (emoji→reaction_type).
- **v2 `LIVE-CONFIRM`.** Exact v2 post/comment/reaction routes and the reaction
  `reaction_type` enum strings must be verified against the live v2 API during
  implementation (the client already carries `LIVE-CONFIRM` markers for this
  reason).
