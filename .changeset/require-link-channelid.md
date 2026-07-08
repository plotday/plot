---
"@plotday/twister": minor
---

Changed: `NewLinkWithNotes.channelId` (the type `integrations.saveLink()`/`saveLinks()` accept) is now required instead of optional. It was easy to set `channelId` only inside `meta` and forget the top-level field — that compiled fine but silently broke outbound write-back (`onNoteCreated` reads the channel back from the persisted `channelId`, not from `meta`) and bulk operations like `archiveLinks({ channelId })` on disable, with no error anywhere. The type system now catches this at compile time instead.

Added: `CreateLinkResult` — the return type for `Connector.onCreateLink()`. Identical to `NewLinkWithNotes` except `channelId` stays optional, since the platform auto-fills it from the compose draft when omitted. Connectors implementing `onCreateLink` should update their return type from `NewLinkWithNotes | null` to `CreateLinkResult | null`.
