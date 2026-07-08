---
id: deactivate-cleanup
category: lifecycle
difficulty: medium
assertions:
  - match: 'deactivate'
    why: must override the deactivate lifecycle hook
  - match: 'deleteWebhook|cancelAllTasks|cancelScheduledTask|deleteCallback|clearAll'
    why: deactivate must actually clean up registered resources
  - match: 'createWebhook'
    why: must register the webhook it later cleans up
allowDeps: []
---
# Tidy ping monitor

Register a webhook endpoint that external services can ping; each ping adds
a note to a single "Pings" thread. Also post a short daily status thread
each morning. When this twist is removed from the priority, everything it
set up must be cleaned up: the webhook endpoint, the scheduled daily work,
and any stored state.
