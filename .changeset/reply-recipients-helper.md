---
"@plotday/twister": minor
---

Added: `Note.recipients` — the reply-path analogue of `CreateLinkDraft.recipients`. For connectors whose link type addresses by recipient (`compose.targets: "contacts"` or `"addresses"`, e.g. email), the runtime now pre-resolves a curated reply's recipients to platform account ids / addresses with `to`/`cc`/`bcc` roles, with the acting user's own identities already removed. `null` when the note inherits the conversation's recipients (a plain reply-all).

Added: `resolveOutboundReplyRecipients()` — a shared helper for `sharingModel: "message"` connectors that turns `note.recipients` (or, as a fallback, a header-derived access-contact constraint, or a reply-all) into deduped `to`/`cc`/`bcc` lists with role precedence, so recipient resolution lives in one tested place instead of being re-implemented per connector. Fixes replies that add a recipient who wasn't on the original message being silently dropped.
