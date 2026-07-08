---
id: multi-file
category: structure
difficulty: medium
assertions:
  - match: 'from\s+["'']\.\/'
    why: entry point must import from a sibling module
  - match: 'onNoteCreated'
    why: must react to new notes
allowDeps: []
---
# Date distance replies

Watch for notes containing an ISO date like 2026-07-07. When one appears,
reply in the same thread with a note saying how many days away that date is
(past dates count backwards). Please structure the code well: put the
date-finding and day-counting logic in its own module, separate from the
main entry point, so the logic could be unit tested on its own.
