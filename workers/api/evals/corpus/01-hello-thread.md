---
id: hello-thread
category: smoke
difficulty: easy
assertions:
  - match: 'createThread'
    why: must create a thread
notMatch:
  - pattern: 'extends\s+Connector'
    why: twists extend Twist, not Connector
allowDeps: []
---
# Welcome thread

When this twist is added to a priority, create a single thread titled
"Welcome to my twist" with one note containing a short, friendly markdown
greeting. That is all it should do.
