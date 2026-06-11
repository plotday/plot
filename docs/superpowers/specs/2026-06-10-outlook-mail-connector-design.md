# Outlook Mail Connector — Design

**Date:** 2026-06-10
**Status:** Approved
**Scope decisions (user-confirmed):** folders as channels; People.Read + Contacts.Read enrichment; self-contained package (no shared Graph extraction); verification = build + lint + unit tests + manual E2E plan.

## Goal

A full-functionality Outlook Mail connector in `public/connectors/outlook-mail`, at parity with the Gmail connector: initial + incremental sync, contact enrichment, two-way sync of unread and flagged statuses, reply and compose, attachments, and email-classifier facets. Covers both personal (outlook.com) and work/school (Azure AD) accounts via MS Graph's `/common` OAuth endpoint.

## What already exists (reused, not built)

- **Microsoft OAuth provider** in `workers/api/src/provider.ts` (`AUTH_MICROSOFT_ID/SECRET`, `login.microsoftonline.com/common`). No core-repo auth changes needed.
- **`/hook-sync/:token`** in `workers/api/src/webhook.ts` already echoes Graph's `validationToken` as plain text — the subscription handshake works today.
- **`outlook-calendar`** (`public/connectors/outlook-calendar`) provides a proven `GraphApi` client shape, subscription create/renew/delete timing (3-day lifetime, 24h renewal lead), and Microsoft logo set.
- **Gmail connector** (`public/connectors/gmail`) is the architectural template for everything else.

## Package

`@plotday/connector-outlook-mail` at `public/connectors/outlook-mail/`:

- `src/index.ts` — exports `{ default, OutlookMail }`.
- `src/outlook-mail.ts` — connector class.
- `src/graph-api.ts` — self-contained Graph client (adapted from outlook-calendar's; not shared) + message parsing/transform helpers.
- `src/enrich.ts` — contact enrichment from `/me/people` + `/me/contacts`.
- `src/outlook-facets.ts` — facet signals for `@plotday/email-classifier`.
- New `plotTwistId`, `category: "messaging"`, display name "Outlook Mail", description matching the existing `connections.ts` stub. Logos: same set as outlook-calendar.
- Dependencies: `@plotday/twister` (workspace), `@plotday/email-classifier` (workspace).
- No Twister/SDK changes → no changeset. ms-teams and outlook-calendar untouched.

## Connector class

- `provider = AuthProvider.Microsoft`; `handleReplies = true`.
- Scopes via `Integrations.MergeScopes`: `https://graph.microsoft.com/Mail.ReadWrite`, `.../Mail.Send`, `.../People.Read`, `.../Contacts.Read`. (Provider layer adds identity scopes; follow outlook-calendar regarding `offline_access`.)
- `linkTypes`: one `email` type mirroring Gmail's — `sharingModel: "message"`, compose/reply verbs, `supportsFileAttachments`, `supportsContactChanges`, To/CC/BCC contact roles, `compose: { targets: "addresses" }`.
- `build()`: `integrations`, `network` (urls: `https://graph.microsoft.com/*`), `files`.

## Channels

`getChannels()` lists `/me/mailFolders` (top-level, paged), excluding well-known noise folders: Junk Email, Deleted Items, Drafts, Outbox, Conversation History. Channel id = folder id, title = `displayName`. Folder enablement gates **backfill only**; incremental sync is mailbox-wide (Gmail label semantics).

## Sync architecture

### Initial sync (per enabled folder)

`onChannelEnabled` (idempotent, honors `context.recovering` to drop stale cursors) queues `initialSyncBatch(folderId, 1)` via `runTask`, plus mailbox subscription setup. Each batch: page `/me/mailFolders/{id}/messages` newest-first (`$orderby=receivedDateTime desc`, `$top=20`, `$filter=receivedDateTime ge {syncHistoryMin}` when provided), group page hits by `conversationId`, fetch each full conversation (`/me/messages?$filter=conversationId eq '...'`), transform, save with `initialSync=true` (unread/archived suppressed). Persist `@odata.nextLink` cursor in `initial_state_{folderId}`; recurse via `runTask` while more pages; finish with `integrations.channelSyncCompleted(folderId)`.

### Incremental sync (mailbox-wide)

One Graph subscription: resource `/me/messages`, changeTypes `created,updated`, notification URL from `this.tools.network.createWebhook(...)` → `/hook-sync/:token`, `clientState` random secret verified on every notification. Lifetime ~3 days (4230-minute Outlook cap), renewal task scheduled 24h before expiry; renewal failure falls back to delete-and-recreate.

Notification handler: ack fast, queue `incrementalSyncBatch` with the notified message ids. Batch: fetch each message (minimal `$select` incl. `conversationId`, `parentFolderId`), skip Junk/Deleted/Drafts, fetch the full conversation, transform, save with `initialSync=false`. Failed fetches carried in `pendingIds` with attempt counters (max 5), Gmail-style.

### Self-heal (Gmail pattern, 60-minute cycle)

While ≥1 channel enabled: (1) per-enabled-folder delta catch-up via `/me/mailFolders/{id}/messages/delta` (delta tokens in `delta_{folderId}`; on token expiry, reseed); (2) verify subscription exists and isn't within 36h of expiry, recreate if missing/imminent; (3) heartbeat log of action taken. Always reschedules itself, even on error.

## Entity mapping

- **Thread:** one Plot thread per Outlook conversation. `source` = stable URI built from `conversationId` (stable across folder moves; per-mailbox like Gmail's threadId). `sourceUrl` = `message.webLink` (latest message, best-effort). `title` = subject, `preview` = `bodyPreview`, `access: "private"`, thread-level `accessContacts` = deduped From/To/Cc across messages. `meta`: `{ conversationId, syncProvider: "microsoft", syncableId, channelId }`.
- **Notes:** one per non-draft message, `key = internetMessageId` (survives folder moves, matches sent-mail echoes). `author` from `from` header, `created = receivedDateTime`, body as `contentType: "html"` with quoted history stripped (reuse Gmail's stripper patterns — it already detects Outlook quote headers), `checkForTasks: true`, per-message `accessContacts`.
- **Graph id instability:** request `Prefer: IdType="ImmutableId"` on all Graph calls; where unsupported, resolve messages by `$filter=internetMessageId eq '...'` fallback.
- **Attachments:** `fileRef` actions, `ref = {graphMessageId}:{attachmentId}`, on-demand download via `/attachments/{id}` (`contentBytes` base64). `outlook:msg-channel:{messageId}` fast-path cache like Gmail's.
- **Facets:** `@plotday/email-classifier` fed from `internetMessageHeaders` of the parent message (List-Id, Precedence, etc. — requires `$select=internetMessageHeaders` on that fetch), recipient counts, is-reply, and `inferenceClassification` (Focused/Other) as the provider category signal.

## Contact enrichment

Single batch per sync batch (Gmail pattern): collect all participant emails → match against `/me/people` (relevance-ranked, includes non-saved frequent correspondents) and `/me/contacts` → fill display names and photos. Photos best-effort (`/me/contacts/{id}/photo/$value`; people photos where exposed); personal accounts restrict cross-user photo reads — degrade silently, Gravatar fallback remains client-side. Enrichment failures never fail the sync.

## Two-way status sync

Gmail's exact echo-prevention discipline: cache new state **before** the outbound Graph call; diff inbound state against cache before propagating to Plot.

- **Unread:** `onThreadRead` → PATCH `{isRead}` on each message in the conversation that differs (Graph has no conversation-level PATCH). Inbound: conversation unread = any non-Sent message `isRead=false`; compare to `unread:{conversationId}`.
- **Flagged ↔ To Do:** `onThreadToDo` → PATCH `{flag: {flagStatus: "flagged"|"notFlagged"}}` on the latest message (clearing: every flagged message). `skip_todo_writeback:{conversationId}` guard flag, Gmail-style. Inbound: flagged = any message `flagStatus="flagged"`; compare to `flagged:{conversationId}`. Initial sync seeds caches without propagating.

## Reply & compose

- **Reply (`onNoteCreated`):** resolve target message (via `meta.reNoteKey` or latest) → `createReply`/`createReplyAll` draft → compute recipients with Gmail's access-constraint logic (`accessContacts` filtering, exclude self) and PATCH `toRecipients`/`ccRecipients` + body → attach files (direct POST `fileAttachment` ≤3MB; upload session above) → read draft's `internetMessageId` → `/send` → return `{ key: internetMessageId }`. Idempotency `send_note:{noteId}`; echo suppression `sent:{internetMessageId}`. Zero allowed recipients → skip send, log.
- **Compose (`onCreateLink`):** create draft via POST `/me/messages` (yields `conversationId` + `internetMessageId` up front) → recipients by role (To/CC/BCC + `inviteEmails`) → attach → `/send` → return `NewLinkWithNotes` with `originatingNote: { key: internetMessageId }` and `source` from the draft's `conversationId`. 10-minute `compose:{hash}` idempotency window. Header-injection sanitization on subject/recipients.

## Teardown & lifecycle

`onChannelDisabled`: clear per-folder state; when no channels remain, delete the Graph subscription, cancel renewal + self-heal tasks, clear mailbox state. Webhook deletion best-effort with logged failures. Localhost guard in subscription setup (Graph can't reach localhost — skip with log, like other connectors).

## Personal vs work account differences

Single code path via `/common`; graceful degradation where consumer accounts differ: People API returns limited data; photo endpoints may 404/403 (silently skipped); `inferenceClassification` used only when present; ImmutableId preference with `internetMessageId` fallback. No tenant-specific branches.

## Error handling

- Graph 429/503: respect `Retry-After`, bounded retries in the client.
- Subscription loss (404 on renewal, missed notifications): self-heal recreates and delta catch-up fills gaps.
- Per-message fetch failures: `pendingIds` retry queue (max 5 attempts).
- Sync batches rethrow on unrecoverable errors so the runtime captures to PostHog; connectors log via `console.error` (no PostHog access in sandbox).

## Testing & verification

- `pnpm build` + lint green in the new package and `workers/api` (no changes expected there, but verify).
- Vitest unit tests (add minimal config if no public connector has one): conversation→link transform (participants, note keys, HTML handling, attachments), recipient/access-constraint logic, unread/flag diffing + echo-prevention state transitions, facet signal extraction, header sanitization.
- Deliverable includes a manual E2E test plan (Azure app scope additions if needed, tunnel setup, personal + work account passes).

## Out of scope

Deploying the connector; flipping `available: true` in `apps/site/app/data/connections.ts`; Azure app registration changes; shared Graph package extraction; refactoring outlook-calendar/ms-teams; calendar/contacts channels beyond mail.

## Workflow

Main repo folder (no core-repo code changes expected); branch the `public/` submodule from current `main` (purely additive package). Separate PR for the submodule per finalize rules.
