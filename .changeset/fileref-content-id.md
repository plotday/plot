---
"@plotday/twister": minor
---

Added: `contentId` on `ActionType.fileRef` actions.

Marks a file reference as an inline body image rather than an attachment. Set
it to the part's Content-ID (without angle brackets) when the note's content
still carries a matching `cid:` reference, and Plot renders the image where the
sender placed it, at its own size, instead of appending an attachment chip.

Mail connectors should use this to distinguish three cases: an ordinary
attachment (no `contentId`), an inline image the retained content still
references (`contentId` set), and an inline image whose only reference lived in
quoted history that was trimmed away — a signature logo, typically — which
should be dropped rather than surfaced as an attachment nobody can place.
