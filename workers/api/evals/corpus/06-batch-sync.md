---
id: batch-sync
category: batching
difficulty: hard
assertions:
  - match: 'runTask'
    why: long imports must be batched into fresh executions
  - match: 'store|this\.set\b|this\.get\b'
    why: progress must persist between batches (generic call forms like this.set<number>(...) count)
allowDeps: []
---
# Open Library reading list import

Import science-fiction books from the Open Library search API
(https://openlibrary.org/search.json?q=subject:science_fiction — it is
paginated and can return thousands of results). Import them in the
background without timing out, keeping track of progress so an interrupted
import picks up where it left off instead of starting over. Each book
becomes a thread titled with the book title, with a note naming the author
and year.
