---
"@plotday/twister": minor
---

Removed: `Integrations.actAs()` has been removed.

Added: `Connector.onNoteReactionChanged(note, thread, actor, emoji, added)` — called once per `(note, actor, emoji)` add/remove event. Dispatch is routed to the reacting user's own connector instance via `twist_instance_for_actor`, so the callback already runs under that user's auth — fetch the API client with the connector's normal token-fetch helper and the write-back (e.g. Slack `reactions.add`) is correctly attributed.

The same per-actor routing is applied to `Connector.onScheduleContactUpdated`, so RSVP write-backs no longer need `actAs` either — use `this.tools.integrations.get(channelId)` (or your connector's existing `getApi(channelId)` helper) directly. Calendar and Slack connectors have been updated; any other connector calling `actAs()` should drop the wrapper and use its own auth.
