---
id: ai-intents
category: ai
difficulty: medium
assertions:
  - match: 'onNoteCreated'
    why: must react to new notes
  - match: '\bai\b|\bAI\b'
    why: must use the AI tool for the summary
  - match: 'createNote'
    why: must reply with a note in the same thread
allowDeps: []
---
# Thread summarizer

When someone writes a note in a thread that asks for a summary (for example
"summarize this thread" or "tl;dr"), reply in that same thread with a new
note containing a concise summary of the thread's notes so far. Use AI to
write the summary. Do not react to notes that this twist wrote itself.
