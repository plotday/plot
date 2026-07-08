---
id: webhook-handler
category: webhook
difficulty: medium
assertions:
  - match: 'createWebhook'
    why: must register a webhook endpoint
  - match: 'createThread'
    why: each push becomes a thread
allowDeps: []
---
# GitHub push notifications

I want to see GitHub pushes in Plot. Set up an HTTPS endpoint I can paste
into a GitHub repository's webhook settings (it will receive standard GitHub
push event JSON). For each push received, create a thread titled with the
repository name and branch, whose note lists the commit messages in that
push.
