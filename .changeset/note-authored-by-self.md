---
"@plotday/twister": minor
---

Added: `NewNote.authoredBySelf` — mark a note as authored by the connection owner. The runtime attributes it to the owner's own contact for that connection, so messaging connectors no longer need to resolve the connected user's own identity from the external service (which is unreliable — a message you sent often carries no usable sender id, and 1:1 chats omit you from the participant roster).
