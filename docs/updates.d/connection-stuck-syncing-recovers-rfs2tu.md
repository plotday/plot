### Fixes

- A connection that got interrupted while first syncing (for example, Gmail & Calendar) could stay stuck showing "Syncing" indefinitely. These are now detected and retried automatically, and fall back to "Reconnect" if they can't recover.

