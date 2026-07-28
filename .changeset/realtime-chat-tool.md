---
"@plotday/twister": minor
---

Added: the `Chat` built-in tool for realtime conversations.

A twist can now attach a chat action to a note. Tapping it opens a
conversation the user can speak or type, with the same agent either way.
Each completed turn is written into the thread as a note, and when the
conversation ends the twist's `onEnded` callback receives the full
transcript to post-process.
