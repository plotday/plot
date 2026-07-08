---
id: scheduled-poll
category: scheduling
difficulty: medium
assertions:
  - match: 'scheduleRecurring|scheduleTask|runTask'
    why: must schedule recurring background work
  - match: 'fetch\('
    why: must fetch from the Hacker News API
  - match: 'createThread'
    why: must create the digest thread
allowDeps: []
---
# Morning Hacker News digest

Every morning at 8am, fetch the current top five stories from the public
Hacker News API (https://hacker-news.firebaseio.com/v0/topstories.json gives
story ids; https://hacker-news.firebaseio.com/v0/item/<id>.json gives each
story's title and url) and create one thread titled "HN digest for <date>"
whose note lists each story title as a markdown link to the story url.
