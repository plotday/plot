# Plot Development Guide for AI Assistants

This guide helps AI assistants build Plot sources and twists correctly.

## What Are You Building?

### Building a Source (service integration)

Sources are packages that connect to external services (Linear, Slack, Google Calendar, etc.). They extend Source and save data directly via `integrations.saveThread()`.

**Start here:** `sources/AGENTS.md` — Complete source development guide with scaffold, patterns, and checklist.

**Choose your interface:**

| Interface | For | Import |
|-----------|-----|--------|
| `CalendarSource` | Calendar/scheduling | `@plotday/twister/common/calendar` |
| `ProjectSource` | Project/task management | `@plotday/twister/common/projects` |
| `MessagingSource` | Email and chat | `@plotday/twister/common/messaging` |
| `DocumentSource` | Document/file storage | `@plotday/twister/common/documents` |

### Building a Twist (orchestrator)

Twists are the entry point that users install. They declare which tools to use and implement domain logic.

**Start here:** `twister/cli/templates/AGENTS.template.md` — Twist implementation guide.

## Type Definitions

All types in `twister/src/` with full JSDoc:

- **Source base**: `twister/src/source.ts`
- **Tool base**: `twister/src/tool.ts`
- **Twist base**: `twister/src/twist.ts`
- **Built-in tools**: `twister/src/tools/*.ts`
  - `callbacks.ts`, `store.ts`, `tasks.ts`, `plot.ts`, `ai.ts`, `network.ts`, `integrations.ts`, `twists.ts`
- **Common interfaces**: `twister/src/common/*.ts`
  - `calendar.ts`, `messaging.ts`, `projects.ts`, `documents.ts`
- **Core types**: `twister/src/plot.ts`, `twister/src/tag.ts`

## Additional Resources

- **Full Documentation**: <https://twist.plot.day>
- **Building Sources Guide**: `twister/docs/BUILDING_TOOLS.md`
- **Runtime Environment**: `twister/docs/RUNTIME.md`
- **Tools Guide**: `twister/docs/TOOLS_GUIDE.md`
- **Multi-User Auth**: `twister/docs/MULTI_USER_AUTH.md`
- **Sync Strategies**: `twister/docs/SYNC_STRATEGIES.md`
- **Working Source Examples**: `sources/linear/`, `sources/google-calendar/`, `sources/slack/`, `sources/jira/`

## Common Pitfalls

1. **❌ Using instance variables for state** — Use `this.set()`/`this.get()` (state doesn't persist between executions)
2. **❌ Long-running operations without batching** — Break into chunks with `runTask()` (~1000 requests per execution)
3. **❌ Passing functions to `this.callback()`** — See `sources/AGENTS.md` for callback serialization pattern
4. **❌ Forgetting sync metadata** — Always inject `syncProvider` and `channelId` into `thread.meta`
5. **❌ Not handling initial vs incremental sync** — `unread: false` for initial, omit for incremental
6. **❌ Missing localhost guard in webhooks** — Skip webhook registration when URL contains "localhost"

---

**Remember**: When in doubt, check the type definitions in `twister/src/` and study the working examples in `sources/`.
