---
id: note-reaction
category: events
difficulty: easy
assertions:
  - match: 'onNoteCreated'
    why: must react to new notes
  - match: 'TODO'
    why: must look for the TODO marker
  - match: 'createThread'
    why: must create the task thread
allowDeps: []
---
# TODO catcher

Whenever a note is added anywhere in this priority that contains the text
"TODO:", create a new task thread whose title is the text that follows
"TODO:" on that line, with a note linking back to the thread where it was
written.
