# RSVP Fold

Shared rule for folding a calendar attendee's response (accept / decline /
tentative) onto the event's thread as a note.

## What it does

- `foldRsvp({ uid, reply, note, readMarker, writeMarker, saveNote })` — folds
  one response onto its event's thread, owning the order the rules below have
  to be applied in: check for a repeat first, only then decide whether the
  response earns a note, and record it only when one was actually written.
  Getting that order wrong re-raises unread on threads people have already
  read, so connectors call this rather than sequencing the predicates
  themselves. Reading and writing the marker, and saving the note, are
  injected — connectors differ in how they batch those.
- `composeRsvpNote(reply)` — formats the one-line note (plus the responder's
  personal comment, when they left one) that a connector attaches to the
  event thread.
- `shouldEmitRsvpNote(reply, hadPriorNonAccept)` — decides whether a response
  earns a note at all. A bare acceptance repeats what the event's guest list
  already shows, so it is deliberately suppressed — attaching any note marks
  the thread unread for everyone but the note's author, and suppression is
  the only way to avoid that for a response carrying no new information.
- `priorRsvpKey(uid, attendeeEmail, occurrence)` — the storage key a connector
  uses to remember an outstanding decline/tentative for one attendee on one
  event (or occurrence, for a recurring series), so a later bare acceptance
  can be recognised as a real change of state.

Connectors that sync calendar invitations (Google Calendar, Outlook) supply
their own attendee response as an `RsvpReply` and share this one rule, so the
same event produces the same note and the same unread behaviour regardless of
which calendar it came from.

## License

MIT © Plot Technologies Inc.
