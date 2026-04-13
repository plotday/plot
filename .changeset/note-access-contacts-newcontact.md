---
"@plotday/twister": minor
---

Changed: NewNote.accessContacts now accepts NewContact objects (email-based) in addition to ActorId UUIDs, resolved server-side. Mentions on notes are for twist/connector dispatch routing only — removed person contacts from mentions in Gmail and Slack connectors.
