# Plot Development Guide for AI Assistants

This guide helps AI assistants build Plot tools and twists correctly.

## Documentation Structure

- **Building Twists**: See `twister/cli/templates/AGENTS.template.md` (auto-generated when creating new twist)
- **Building Tools**: See `tools/AGENTS.md` (critical callback patterns)
- **Type Definitions**: All types are in `twister/src/*.ts` with comprehensive JSDoc
- **Full Documentation**: <https://twist.plot.day>

## Type Definitions

All type definitions are in `twister/src/` with full JSDoc:

- **Tool base**: `twister/src/tool.ts`
- **Twist base**: `twister/src/twist.ts`
- **Built-in tools**: `twister/src/tools/*.ts`
  - `callbacks.ts`, `store.ts`, `tasks.ts`, `plot.ts`, `ai.ts`, `network.ts`, `integrations.ts`
- **Common interfaces**: `twister/src/common/*.ts`
  - `calendar.ts`, `messaging.ts`, `projects.ts`
- **Core types**: `twister/src/plot.ts`, `twister/src/tag.ts`

## Additional Resources

- **Full Documentation**: <https://twist.plot.day>
- **Building Tools Guide**: `twister/docs/BUILDING_TOOLS.md`
- **Runtime Environment**: `twister/docs/RUNTIME.md`
- **Tools Guide**: `twister/docs/TOOLS_GUIDE.md`
- **Twist Development**: `twister/cli/templates/AGENTS.template.md`
- **Working Examples**: `tools/google-calendar/`, `tools/google-contacts/`, `tools/linear/`

## Common Pitfalls

1. **❌ Using instance variables for state** - Use `this.set()`/`this.get()` instead (state doesn't persist between executions)
2. **❌ Long-running operations without batching** - Break into chunks with `runTask()` (request limits: ~1000 per execution)
3. **❌ Forgetting to clean up** - Delete callbacks and stored state when done
4. **❌ Not handling missing auth** - Always check for stored tokens before operations
5. **❌ Passing functions to `this.callback()`** - See `tools/AGENTS.md` for critical callback serialization pattern

---

**Remember**: When in doubt, check the type definitions in `twister/src/` and study the working examples in `tools/`.
