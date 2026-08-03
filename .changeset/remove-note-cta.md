---
"@plotday/twister": minor
---

Removed: `cta` from the note type.

The ephemeral one-time-code prompt this field fed has been retired, and the
value is no longer stored. Connectors that set it should remove the assignment;
the field is ignored in the meantime. One-time-code and confirmation mail is
still identified during classification — that detection is unchanged.
