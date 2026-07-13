# Outlook Mail Connector

> **Library note:** This package is consumed by [`@plotday/connector-outlook`](../outlook), the deployed "Outlook" connection — it is not deployed as a standalone connector. See `../AGENTS.md` for details.

Syncs Microsoft Outlook mail (personal outlook.com and work/school Microsoft 365
accounts) into Plot via Microsoft Graph. Each Outlook conversation becomes a
Plot thread; each message becomes a note on that thread.

## What it syncs

- **Channels** are mail folders (`/me/mailFolders`). Inbox and Sent Items are
  enabled by default; Junk, Deleted Items, Drafts, Outbox, and Conversation
  History are never offered. Enabling a folder backfills its history;
  incremental changes are mailbox-wide (one Graph change-notification
  subscription on `/me/messages`) and routed to whichever enabled folder the
  conversation lives in.
- **Notes** are keyed on `internetMessageId`, so folder moves and the echo of
  mail sent from Plot dedupe cleanly. Drafts are skipped (Outlook autosave
  would churn notes).
- **Attachments** sync as file references and download on demand. Inline
  images are skipped.
- **Facets** for Plot's classifier come from RFC 5322 headers (List-Id,
  Precedence, Auto-Submitted, …) plus Outlook's Focused Inbox
  (`inferenceClassification`).

## Two-way sync

| Plot action | Outlook effect |
|---|---|
| Mark thread read / unread | `isRead` PATCHed on the conversation's messages (unread marks the latest message, read clears all) |
| Add / remove To Do | `flag.flagStatus` set to `flagged` on the latest message / cleared on all flagged messages |
| Reply on a thread | Graph `createReply` draft, recipients constrained by the note's access contacts, then sent |
| New email thread | Graph draft + send, To/CC/BCC from the compose roster |

Outlook-side changes flow back the other way: reading, flagging, replying, and
new mail all arrive via change notifications (with a 60-minute delta-query
self-heal catching anything push delivery misses).

## OAuth scopes

| Scope | Why |
|---|---|
| `Mail.ReadWrite` | Read folders/messages, update read + flag state, create drafts |
| `Mail.Send` | Send replies and new mail composed in Plot |
| `People.Read` | Resolve display names for frequent correspondents who aren't saved contacts |
| `Contacts.Read` | Resolve display names from saved contacts |

## Known limitations

- **Avatars are not enriched.** Microsoft Graph photo endpoints return
  auth-gated binary data with no public URL, so there is nothing to store in
  `contact.avatar`. Contact *names* are enriched from People/Contacts; avatars
  fall back to Gravatar on the client.
- **Personal accounts degrade gracefully.** The People API returns limited
  data for consumer accounts and may 403; enrichment is best-effort per
  address. Focused Inbox signals are used only when present.
- Reply bodies are sent as plain text without the quoted-history block (Plot
  threads already carry the history as notes) — same behavior as the Gmail
  connector.

## Manual E2E test plan

Prerequisites: the Azure app registration (see `docs/outlook.md` in the core
repo) must include the delegated scopes `Mail.ReadWrite`, `Mail.Send`,
`People.Read`, `Contacts.Read`; `AUTH_MICROSOFT_ID`/`AUTH_MICROSOFT_SECRET`
set in `workers/api/.dev.vars`; tunnel running (`pnpm tunnel:start`) so Graph
can reach the webhook endpoint (subscriptions are skipped on localhost).

Run the pass twice: once with a **personal** (outlook.com) account and once
with a **work/school** (Microsoft 365) account.

1. **Connect + channels** — add an Outlook Mail connection; verify the folder
   list excludes Junk/Deleted/Drafts and defaults Inbox + Sent Items on.
2. **Backfill** — enable Inbox; verify threads appear with correct titles,
   per-message notes, participants, timestamps, and that the "Syncing…" badge
   clears. No unread badges from backfilled mail.
3. **Inbound incremental** — send mail to the account from outside; verify the
   thread appears (or extends) within seconds via the subscription.
4. **Unread round-trip** — read a thread in Plot → message marked read in
   Outlook; mark a thread unread in Outlook → unread in Plot. Verify no
   echo loop (state settles after one hop each way).
5. **Flag ↔ To Do round-trip** — flag in Outlook → thread becomes a Plot
   To Do; toggle To Do off in Plot → flag cleared in Outlook.
6. **Reply from Plot** — reply on a synced thread; verify recipients (To/Cc),
   threading in Outlook, and that the sent message does NOT duplicate as a
   new note when it syncs back.
7. **Reply with attachment** — attach a small (<3 MB) and a large (>3 MB)
   file; verify both arrive in Outlook.
8. **Compose from Plot** — new email thread to a typed address + a contact
   with CC; verify delivery, BCC kept out of visible headers, and the
   originating note binds to the sent message.
9. **Attachment download** — open a synced message's attachment in Plot.
10. **Contact names** — verify senders not in the address book still resolve
    display names where People data exists (work tenant), and degrade to
    email-only on personal accounts.
11. **Self-heal** — stop the tunnel for >1 hour, send external mail, restart;
    verify the hourly delta sweep ingests the missed mail and the
    subscription is renewed (check `selfHealCheck` log lines).
12. **Teardown** — disable all folders; verify the Graph subscription is
    deleted (no further webhook traffic) and re-enabling rebuilds it.
