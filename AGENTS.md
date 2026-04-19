# Plot Development Guide for AI Assistants

This guide helps AI assistants build Plot sources and twists correctly.

## What Are You Building?

### Building a Connector (service integration)

Connectors are packages that connect to external services (Linear, Slack, Google Calendar, etc.). They extend Connector and save data directly via `integrations.saveThread()`.

**Start here:** `connectors/AGENTS.md` — Complete connector development guide with scaffold, patterns, and checklist.

### Building a Twist (orchestrator)

Twists are the entry point that users install. They declare which tools to use and implement domain logic.

**Start here:** `twister/cli/templates/AGENTS.template.md` — Twist implementation guide.

## Type Definitions

All types in `twister/src/` with full JSDoc:

- **Connector base**: `twister/src/connector.ts`
- **Tool base**: `twister/src/tool.ts`
- **Twist base**: `twister/src/twist.ts`
- **Built-in tools**: `twister/src/tools/*.ts`
  - `callbacks.ts`, `store.ts`, `tasks.ts`, `plot.ts`, `ai.ts`, `network.ts`, `integrations.ts`, `twists.ts`
- **Core types**: `twister/src/plot.ts`, `twister/src/tag.ts`

## Additional Resources

- **Full Documentation**: <https://twist.plot.day>
- **Building Connectors Guide**: `connectors/AGENTS.md`
- **Runtime Environment**: `twister/docs/RUNTIME.md`
- **Tools Guide**: `twister/docs/TOOLS_GUIDE.md`
- **Multi-User Auth**: `twister/docs/MULTI_USER_AUTH.md`
- **Sync Strategies**: `twister/docs/SYNC_STRATEGIES.md`
- **Plot-initiated item creation (`onCreateLink`)**: `twister/docs/BUILDING_CONNECTORS.md#creating-items-from-plot-oncreatelink`
- **Working Connector Examples**: `connectors/linear/`, `connectors/google-calendar/`, `connectors/slack/`, `connectors/jira/`

## Changesets: Only for `twister/`

Only changes under `twister/` require a changeset. `@plotday/twister` is the only package published to npm from this repo. Connectors (`@plotday/connector-*`) and twists (`@plotday/twist-*`) are listed under `ignore` in `.changeset/config.json` — they deploy via `plot deploy`, not npm.

**Never add a changeset that targets only a connector or twist package.** Such a changeset never resolves: `changeset version` leaves the file in place on every run, so the release workflow perpetually tries to open an empty release PR and fails. `pnpm validate-changesets` (run in CI on every PR) will reject these. See `RELEASING.md` for the full release flow.

## Common Pitfalls

1. **❌ Using instance variables for state** — Use `this.set()`/`this.get()` (state doesn't persist between executions)
2. **❌ Long-running operations without batching** — Break into chunks with `runTask()` (~1000 requests per execution)
3. **❌ Passing functions to `this.callback()`** — See `connectors/AGENTS.md` for callback serialization pattern
4. **❌ Forgetting sync metadata** — Always inject `syncProvider` and `channelId` into `thread.meta`
5. **❌ Not handling initial vs incremental sync** — Propagate `initialSync` flag from entry point (`onChannelEnabled` → `true`, webhook → `false`) through all batch callbacks. Set `unread: false` and `archived: false` for initial, omit for incremental
6. **❌ Missing localhost guard in webhooks** — Skip webhook registration when URL contains "localhost"
7. **❌ Stripping HTML tags locally** — Pass raw HTML with `contentType: "html"` for server-side markdown conversion
8. **❌ Implementing `onCreateLink` without declaring `createDefault`** — A link type opts in to Plot-initiated item creation by marking one status with `createDefault: true` on `LinkTypeConfig.statuses[]`. Without the marker the "Create new …" picker entry never appears, regardless of whether the method is defined

---

**Remember**: When in doubt, check the type definitions in `twister/src/` and study the working examples in `connectors/`.
