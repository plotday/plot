# Granola connector

Syncs AI meeting notes from [Granola](https://granola.ai) into Plot.

When a note's calendar event matches an existing calendar thread (created by
the Google, Outlook, or Apple Calendar connectors), the Granola summary is
attached to that same thread alongside the event details. Otherwise the
connector creates a standalone thread containing just the Granola note.

## Auth

Personal or Enterprise API key from Granola. Paste it into the connector's
**API key** option in Plot.

Get a key at <https://docs.granola.ai/introduction>.

## Cross-connector bundling

The connector emits canonical `sources` aliases that overlap with the
calendar connectors' aliases on the same event:

| Connector | Aliases on each calendar event |
|---|---|
| Google Calendar | `google-calendar:<iCalUID>`, `icaluid:<iCalUID>`, `google-event:<id>` |
| Outlook Calendar | `outlook-calendar:<calendarId>:<eventId>`, `icaluid:<iCalUId>`, `outlook-event:<eventId>` |
| Apple Calendar | `apple-calendar:<UID>`, `icaluid:<UID>` |
| Granola | `granola:note:<id>` + `icaluid:<calendar_event_id>` + namespaced fallbacks |

The runtime's array-overlap upsert (`link.sources && new.sources`) merges
links whose `sources` share any element. Recurring meetings work for free
because all instances share the same iCalUID, so the master thread is
already canonical.
