# Email Client Gaps

Plot today reads Gmail well — real-time Pub/Sub sync, label channels, contact enrichment, HTML→Markdown conversion, bidirectional star/unread/archive — but composes and sends like a chat tool: single recipient field, no attachments, Gmail-only. It is not a full email client.

This is a stack-ranked backlog of remaining gaps to close, ordered roughly by user-visible pain ÷ implementation cost.

## Tier 1 — Table stakes (block "use Plot as my email")

### 1. CC / BCC on compose and reply

Compose only exposes a `To` field; reply recipients are inferred from headers and not editable. `docs/updates.md` admits "CC/BCC coming later"; BCC isn't declared anywhere.

**Sketch:** Extend `apps/plot/lib/widget/contacts_compose_field.dart` and `connection_targets.dart:137` into a three-row layout (To / Cc / Bcc) with show/hide affordance, reusing the existing chip + autocomplete control. Add `cc` / `bcc` arrays to the create-link payload in `public/twister/src/` (changeset, minor bump). Thread them through `gmail.ts onCreateLink()` → `gmail-api.ts:930 sendNewMessage()` MIME builder — RFC 2822 already supports the headers. On the reply path (`gmail.ts:1305-1327`), lift the inferred recipients into editable fields while preserving reply-all defaults.

### 2. Attachments on outbound email

Inbound attachments parse fine (`gmail-api.ts:552`); compose has no file upload. Replies and new emails are markdown-only.

**Sketch:** Add an attach button to the compose toolbar; reuse the existing R2-backed file upload that already stores attachments as `link` rows on the thread. In `gmail.ts onCreateLink()` and the reply path, when the thread has unsent attachment links, fetch from R2 and append as MIME parts — extend `sendNewMessage()` from flat text to multipart/mixed. Gmail caps at 25MB; fall back to "insert Google Drive link" for larger files (Drive connector already exists).

### 3. Email signatures

Emails sent from Plot have no footer. Recipients can't tell the sender's role or company.

**Sketch:** New `user_email_signature` table or a JSON field on the Gmail connection (per-connection — work vs. personal differ). Settings UI under connection details. Append in the connector's `sendNewMessage()` as the last step before MIME build. Optional v2: per-priority signature override, since Plot orients around priorities.

### 4. Streamlined "New Email" entry point

`apps/plot/lib/page/new_thread.dart` defaults to a Plot thread. To send a new email, the user must dig into the connection-picker chip and find "Create new Gmail email" — discoverability is bad.

**Sketch:** Promote create-link targets to a first-class affordance at the top of `new_thread.dart` (or as a quick-action row): "New email", "New Slack message", etc., derived from the same `createDefault` declarations connectors already publish. Pre-select primary Gmail; surface a "Send as" picker when multiple Gmail connections exist.

## Tier 2 — Expected by any serious email user

### 5. Forward action

No way to forward a received email. Reply / reply-all only.

**Sketch:** Add a "Forward" affordance on email-type threads. Branch in `gmail.ts onNoteCreated()` on a new note flag (or new note type) that builds an outbound message with the original body quoted + new recipient list. Requires Tier 1 #1 to be useful.

### 6. Microsoft / Outlook mail connector

Outlook Calendar exists; Outlook Mail does not. Cuts Plot off from a large slice of business users.

**Sketch:** New connector at `public/connectors/outlook-mail/`, mirroring the Gmail connector shape: OAuth scope, mailbox watch via Microsoft Graph change-notification subscriptions (analogous to Gmail Pub/Sub), per-folder channels, RFC 2822 send via Graph `/me/sendMail`. Reuse the provider-agnostic HTML→Markdown pipeline at `gmail-api.ts:405`. Map Graph `conversationId` onto Plot threads the same way Gmail `threadId` is mapped. Significantly cheaper than Gmail was because channels, link types, and write-back hooks are already proven abstractions.

### 7. Scheduled send / send later

Hitting send delivers immediately.

**Sketch:** Compose UI: "Schedule" option on the send button (split-button) with date/time picker. Server: a delayed-dispatch table + Cloudflare cron worker or DO alarm that fires the underlying connector send at the chosen time. Reuse the `this.callback(...)` / runTask infrastructure in `workers/api/src/twist/`. Edit-while-scheduled requires Tier 2 #9 (server-persisted drafts) to be polished.

### 8. Undo send (grace window)

No grace period; send is immediate.

**Sketch:** Cheap version of #7 — every send queues with a 5–15s delay, toast offers Undo. Implement as deferred dispatch with cancellation by note ID. Reuses #7's mechanism; also small standalone.

### 9. Server-persisted drafts

Drafts live in local Drift DB and are lost when switching devices. Replies don't survive a refresh on web.

**Sketch:** New `note_draft` shape or extend `note` with a `draft` flag + sync. The seq-cursor sync infrastructure is already there — add the new shape, gate visibility to the author following the contacts-OR-groups rule in `AGENTS.md`. Connector hook: optionally push to Gmail Drafts (Gmail API supports it) so Plot drafts appear in the native Gmail app too. One-way Plot→Gmail is a good v1; bidirectional is harder.

## Tier 3 — Power-user gaps

### 10. Snooze / follow-up reminders on emails

Plot already has `agenda_at` and thread scheduling. Add a "snooze until X" button that reuses thread scheduling — the email returns to the top of inbox at the chosen time.

### 11. Mark-as-spam / block sender

Map "report spam" to the Gmail SPAM label and "block sender" to a server-side filter rule stored on the connection. Outlook equivalent comes free with #6.

### 12. Server-side filter rules / auto-filing

Today only Gmail-search-based channels exist (read-only auto-fetch). A real filter UI ("from X → file to priority Y, mark read") would be a new `connection_rule` table evaluated in `onLinkUpdated()` / `onLinkCreated()`.

### 13. Bulk operations

Multi-select threads → archive / mark read / move. UI primitive (list checkbox mode) doesn't exist yet; backend mutations are already per-thread idempotent, so a bulk endpoint is mostly a frontend exercise plus a small RPC.

### 14. Generic IMAP/SMTP connector

Catches Proton, Yahoo, Fastmail, Exchange-on-prem. Substantial: Workers can't open arbitrary outbound TCP, so this needs a small IMAP/SMTP proxy service. Not worth it until #6 lands and demand is proven.

### 15. Email-specific keyboard shortcuts

`j/k` next/prev, `e` archive, `#` delete, `s` star, `r` reply, `a` reply-all, `f` forward, `/` search. Plot has a keyboard handling layer; add a thread-list keymap.

### 16. Thread message collapse/expand

Long email threads (10+ messages) render fully expanded. Add Gmail-style collapse for older messages. Pure Flutter UI change in the note list widget.

### 17. Read receipts, .eml/.mbox export, custom labels created from Plot

Niche. Each is a self-contained small task; defer until requested.

## What to build first

The minimum credible cut to stop telling users *"use Gmail for compose, Plot for reading"* is **#1 + #2 + #3 + #4 + #5** — roughly 2-3 weeks of frontend-heavy work that converts Plot from "email reader with quick reply" into "email client I can actually use for outbound." Everything in Tier 2+ is additive after that.
