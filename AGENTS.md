# Plot Development Guide for AI Assistants

This guide helps AI assistants build Plot tools and twists correctly.

## What Are You Building?

### Building a Tool (service integration)

Tools are reusable packages that connect to external services (Linear, Slack, Google Calendar, etc.). They implement a standard interface and are consumed by twists.

**Start here:** `tools/AGENTS.md` — Complete tool development guide with scaffold, patterns, and checklist.

**Choose your interface:**

| Interface | For | Import |
|-----------|-----|--------|
| `CalendarTool` | Calendar/scheduling | `@plotday/twister/common/calendar` |
| `ProjectTool` | Project/task management | `@plotday/twister/common/projects` |
| `MessagingTool` | Email and chat | `@plotday/twister/common/messaging` |
| `DocumentTool` | Document/file storage | `@plotday/twister/common/documents` |

### Building a Twist (orchestrator)

Twists are the entry point that users install. They declare which tools to use and implement domain logic (filtering, enrichment, two-way sync).

**Start here:** `twister/cli/templates/AGENTS.template.md` — Twist implementation guide.

## Type Definitions

All types in `twister/src/` with full JSDoc:

- **Tool base**: `twister/src/tool.ts`
- **Twist base**: `twister/src/twist.ts`
- **Built-in tools**: `twister/src/tools/*.ts`
  - `callbacks.ts`, `store.ts`, `tasks.ts`, `plot.ts`, `ai.ts`, `network.ts`, `integrations.ts`, `twists.ts`
- **Common interfaces**: `twister/src/common/*.ts`
  - `calendar.ts`, `messaging.ts`, `projects.ts`, `documents.ts`
- **Core types**: `twister/src/plot.ts`, `twister/src/tag.ts`

## Additional Resources

- **Full Documentation**: <https://twist.plot.day>
- **Building Tools Guide**: `twister/docs/BUILDING_TOOLS.md`
- **Runtime Environment**: `twister/docs/RUNTIME.md`
- **Tools Guide**: `twister/docs/TOOLS_GUIDE.md`
- **Multi-User Auth**: `twister/docs/MULTI_USER_AUTH.md`
- **Sync Strategies**: `twister/docs/SYNC_STRATEGIES.md`
- **Working Tool Examples**: `tools/linear/`, `tools/google-calendar/`, `tools/slack/`, `tools/jira/`
- **Working Twist Examples**: `twists/calendar-sync/`, `twists/project-sync/`

## Common Pitfalls

1. **❌ Using instance variables for state** — Use `this.set()`/`this.get()` (state doesn't persist between executions)
2. **❌ Long-running operations without batching** — Break into chunks with `runTask()` (~1000 requests per execution)
3. **❌ Passing functions to `this.callback()`** — See `tools/AGENTS.md` for callback serialization pattern
4. **❌ Calling `plot.createActivity()` from a tool** — Tools build data, twists save it
5. **❌ Forgetting sync metadata** — Always inject `syncProvider` and `syncableId` into `activity.meta`
6. **❌ Not handling initial vs incremental sync** — `unread: false` for initial, omit for incremental
7. **❌ Missing localhost guard in webhooks** — Skip webhook registration when URL contains "localhost"

---

**Remember**: When in doubt, check the type definitions in `twister/src/` and study the working examples in `tools/`.
