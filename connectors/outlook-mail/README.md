# Outlook Mail Connector

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
