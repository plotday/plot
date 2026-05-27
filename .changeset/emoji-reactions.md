---
"@plotday/twister": minor
---

Added: `Reaction`, `Reactions`, `NewReactions` types and a `reactions` field on `ThreadCommon` (covering both `Thread` and `Note`), along with optional `reactions?: NewReactions` on `NewThread`, `NewNote`, `ThreadUpdate`, `NoteUpdate`. Also adds `Connector.reactionCapabilities` (open-unicode / unicode-subset / fixed) so the Plot picker and outbound dispatch can filter reactions to what the source platform supports. Foundation for higher-fidelity emoji reaction sync across Slack, Microsoft Teams, Google Chat, LinkedIn Messaging, and Plot-native threads.
