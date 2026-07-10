# GitHub PR thread improvements

**Date:** 2026-07-10
**Status:** Draft — approved via brainstorming conversation, ready for planning
**Author:** Kris + Claude
**Related:** `project_google_composite_connector_missing_handlereplies` (write-back dispatch gating on `handleReplies`), `project_twist_instance_connection_fk_readpath_selfheal` (connection-row drift, fixed separately on branch `fix/tic-connection-drift`)

## Problem

Four requested improvements to how GitHub Pull Request threads work in Plot:

1. Include the PR description as a note.
2. Sync notes from Plot to PR comments (GitHub→Plot direction already works).
3. Two-way sync reactions.
4. Add an "Open in GitHub" action, like the existing "Open in Gmail."

Investigation before design found the actual gaps are narrower — and one adjacent
data-integrity bug wider — than the request implied:

- **#1 and #4 are already implemented**, but only in the batch/initial-sync path
  (`convertPRToThread` in `public/connectors/github/src/pr-sync.ts`). The
  incremental webhook handlers (`handlePRWebhook`, `handleReviewWebhook`,
  `handlePRCommentWebhook`) never set `sourceUrl`, the `Action.external` "Open in
  GitHub" button, or the `description`-keyed note. A PR whose *first* sync into
  Plot happens via webhook (e.g. opened after the connection is already live)
  is missing both until a later resync backfills it.
- **#2 is fully implemented** (`onNoteCreated`/`onNoteUpdated` in
  `public/connectors/github/src/github.ts` → `addPRComment`/`updateIssueComment`)
  but was not firing in practice. Root cause turned out to be an unrelated
  platform bug: a missing `twist_instance_connection` row (see
  `project_twist_instance_connection_fk_readpath_selfheal` and the fix landed on
  branch `fix/tic-connection-drift`, commit `6fc5958f7`) meant `user_connected`
  was `false`, so the Flutter client never auto-mentioned the GitHub connector
  on a plain reply, so the write-back dispatch (gated purely on `note.mentions`)
  never fired. That bug is fixed separately; this spec only needs to *verify*
  #2 now works, not build it.
- **#3 (reactions) is genuinely new** — no reaction sync exists today — and
  during design turned up a real prerequisite: GitHub has no webhook for
  reactions on comments (confirmed against GitHub's webhook events reference:
  neither `issue_comment` nor `pull_request_review_comment` carries a
  reaction-change action, and there is no dedicated reaction event), so inbound
  sync must poll. Additionally, "reactions on both comment types" surfaced that
  **inline PR review comments (code-line comments) aren't synced into Plot at
  all today** — only top-level PR/issue comments are. Reactions need something
  to attach to, so this spec includes syncing inline review comments as a
  prerequisite.

## Scope

In scope, in dependency order:

1. Webhook-path field parity fix (#1 + #4).
2. Inline PR review-comment sync, inbound + reply-only outbound (prerequisite for reactions-on-both).
3. Two-way reaction sync, both comment types.
4. Verification that #2 (Plot→GitHub note write-back) works end-to-end now that the connection-drift bug is fixed.

**Explicitly out of scope** (deferred during brainstorming):

- Triggering a real GitHub merge when a thread's status is changed to `merged`
  in Plot. Today status→`merged` only submits an approving review
  (`updatePRStatus`); actually merging is a one-way door with method-choice and
  failure-handling questions that weren't decided. No status-change behavior
  changes in this spec.
- Creating brand-new inline review comments from Plot (as opposed to replying
  to an existing inline-comment thread). GitHub requires a file/line/commit
  position to create one; Plot has no diff-picking UI to supply that. Only
  replies (which don't need position — GitHub inherits it from the parent) are
  in scope.

## Component 1: Webhook-path field parity fix

`convertPRToThread` (batch/initial sync) sets three things the three incremental
webhook handlers don't:

- `sourceUrl: pr.html_url` — this is what makes the *generic* "Open in GitHub"
  link appear (`apps/plot/lib/command/thread.dart`'s `OpenThreadLink` renders
  for any primary link with `sourceUrl`, the same mechanism "Open in Gmail"
  uses — there's no GitHub-specific client code to add).
- `actions: [Action.external(...)]` — an explicit "Open in GitHub" button,
  distinct from the generic source link.
- A `key: "description"` note carrying `pr.body`.

**Fix:** extract this shared field-population (source URL + action + description
note) into one function both `convertPRToThread` and the three webhook handlers
call, so a PR that first lands in Plot via webhook gets full parity immediately.
`handlePRWebhook` should emit/update the `description` note on `opened` and
`edited` actions (matching `key: "description"` for correct upsert against
whatever `convertPRToThread` may have already written).

## Component 2: Inline PR review-comment sync

### Inbound

- Register the `pull_request_review_comment` webhook event (`created`/`edited`/`deleted`
  actions) alongside the existing `pull_request`, `pull_request_review`, `issues`,
  `issue_comment` subscriptions (`setupWebhook` in `github.ts`).
- During batch sync, additionally fetch `/repos/{owner}/{repo}/pulls/{number}/comments`
  (paginated), mirroring the existing `/issues/{n}/comments` fetch in
  `convertPRToThread`.
- Each inline comment becomes a note with **`key: review-comment-${id}`** — a
  prefix distinct from the existing `comment-${id}` (top-level) and `review-${id}`
  (review summaries: approve/request-changes/dismiss) so that reaction sync and
  write-back can tell which GitHub API namespace (`/issues/comments/` vs.
  `/pulls/comments/`) an id belongs to, since GitHub's two comment id spaces are
  otherwise just disjoint integers with no type marker.
- Note content renders file/line context as a short header, not a diff-hunk dump:
  `📄 {path}:{line}`, blank line, then the comment body. (GitHub gives both `path`
  and `line`/`position` on the payload.)
- When a comment is a reply to another inline comment (GitHub's `in_reply_to_id`),
  map it to Plot's native `re_note_id` threading field so replies nest under their
  parent instead of appearing as flat siblings in the thread.

### Outbound

- Only **replies** to an existing inline-comment thread are supported outbound —
  GitHub's reply endpoint (`POST .../pulls/comments` with `in_reply_to`) doesn't
  need a position, unlike creating a fresh inline comment. `onNoteCreated` for a
  note whose parent (`re_note_id`) resolves to a `review-comment-*` note routes
  to this endpoint instead of `addPRComment`.
- `onNoteUpdated` for a `review-comment-*` note edits via `/pulls/comments/{id}`,
  mirroring the existing `updateIssueComment` pattern for top-level comments.

## Component 3: Two-way reaction sync

### Emoji mapping

GitHub's reaction set is fixed. Declare `reactionCapabilities = { mode: "fixed",
allowed: [...] }` with this mapping:

| GitHub | Emoji |
|---|---|
| `+1` | 👍 |
| `-1` | 👎 |
| `laugh` | 😄 |
| `hooray` | 🎉 |
| `confused` | 😕 |
| `heart` | ❤️ |
| `rocket` | 🚀 |
| `eyes` | 👀 |

A user reacting to a GitHub-sourced note in Plot only sees these 8 as options —
same restricted-picker UX Slack's connector already uses for custom-emoji-scoped
workspaces.

### Outbound (Plot→GitHub)

Event-driven, no polling. `onNoteReactionChanged(note, thread, actor, emoji, added)`
reads the `comment-`/`review-comment-` prefix off `note.key` to pick the right
endpoint (`/issues/comments/{id}/reactions` vs. `/pulls/comments/{id}/reactions`)
and calls `POST`/`DELETE` accordingly. Best-effort, non-throwing (matches
`updatePRStatus`/Linear's `onLinkUpdated` write-back pattern) — a failed write
doesn't corrupt local Plot state; the next poll cycle (below) reconciles.

### Inbound (GitHub→Plot)

GitHub has no reaction webhook, so this must poll. A `scheduleRecurring` job runs
every **~15 minutes**, scoped to threads whose link `status = "open"` only
(closed/merged PRs stop getting polled — chosen over a wider "open + recently
closed" window or an on-demand-only approach, to bound recurring API-call volume
against the twist runtime's ~1000-request-per-execution budget).

For each open-PR thread: enumerate its `comment-*`/`review-comment-*` notes
(already known from prior sync — no need to re-fetch GitHub's comment list),
fetch each comment's reactions via the endpoint implied by its key prefix,
resolve each reacting GitHub user to a Plot actor (reusing the existing
author-resolution logic already used for comment authors), and reconcile into
`note.reactions`.

**Reconciliation is scoped, not wholesale.** For each emoji, replace only the
subset of `note.reactions[emoji]` that are GitHub-linked actors with the
freshly-polled set; leave any Plot-native user's reaction on that same note
untouched. A naive full overwrite from the poll would erase a Plot user's own
reaction, since GitHub's reaction list has no knowledge of it.

## Component 4: Verification

Not a build task — after the connection-drift fix (`fix/tic-connection-drift`)
lands and this GitHub connection self-heals, manually verify a new Plot note on
a live PR thread actually reaches GitHub as a comment, confirming the
already-implemented `onNoteCreated` → `addPRComment` path works end-to-end and
not just in isolation.

## Data model

No database schema changes. Everything here is connector-side (twister SDK
declarations + `public/connectors/github/src/*.ts`) plus one new note `key`
prefix convention:

- `description` — PR body (existing)
- `comment-${id}` — top-level PR/issue comment (existing)
- `review-${id}` — PR review summary: approve/request-changes/dismiss (existing)
- `review-comment-${id}` — inline code-line comment (**new**, this spec)

`re_note_id` (existing Plot note field) is used for inline-comment reply
threading — no new field needed.

## Testing

- Unit tests: the emoji mapping table (both directions), the key-prefix → API
  endpoint routing (`comment-*` vs. `review-comment-*`, for both write-back and
  reaction calls), and the reconciliation merge logic (asserts a Plot-native
  actor's reaction survives a poll cycle that doesn't mention them).
- Integration-style test for the webhook-path parity fix: assert `sourceUrl`,
  `actions`, and the `description` note are present after a webhook-only sync
  (PR never went through batch sync), not just after batch sync.
- Inline review-comment sync: webhook-driven create/edit/delete produces the
  right note with `review-comment-` key and `re_note_id` threading; batch sync
  backfill produces the same shape for pre-existing PRs.
- Outbound reply routing: a note whose `re_note_id` resolves to a
  `review-comment-*` parent goes to the reply endpoint, not `addPRComment`.

## Edge cases

- **Comment id collision across namespaces:** GitHub's issue-comment and
  PR-review-comment id spaces are independently allocated but both integers —
  never infer type from the numeric id alone; always route on the `key` prefix.
- **Reaction poll on a comment deleted since last sync:** a single failed
  reactions-GET (404, rate limit) must not abort the whole poll batch for that
  PR or other PRs in the same pass — log and continue.
- **PR merges/closes mid-poll-cycle:** the next poll cycle's open-PR enumeration
  naturally excludes it; no special-case needed, reactions added in the last
  ~15 minutes before close may be missed once (acceptable given the chosen
  scope/cadence trade-off).
- **A GitHub user reacts who has no linked Plot contact/actor:** falls back to
  whatever generic external-actor handling the existing comment-author
  resolution already does (no new behavior needed — same resolution path).

## Out of scope (recap)

- Status-change-triggers-merge (see Scope section above).
- New inline review comments authored from Plot (position/diff-picking UI
  doesn't exist).
- Any change to the connection-drift bug itself — tracked and fixed separately.
