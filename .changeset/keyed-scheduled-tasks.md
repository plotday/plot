---
"@plotday/twister": minor
---

Added: `scheduleTask(key, callback, { runAt })` and `cancelScheduledTask(key)` on the Tasks tool (and as `this.scheduleTask`/`this.cancelScheduledTask` helpers on Twist/Tool). These manage a singleton scheduled task per key — re-scheduling under the same key atomically cancels and replaces any pending task. Use them for recurring/self-renewing jobs (watch/webhook renewals, polling, deferred cleanup) instead of hand-managing tokens with `runTask({ runAt })` + `cancelTask()`, which is easy to get wrong and can leak parallel self-perpetuating task chains.
