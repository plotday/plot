# Tool Development Guide for AI Assistants

This guide focuses on critical patterns for building Plot tools correctly.

**For general information**: See `../AGENTS.md`
**For twist development**: See `../twister/cli/templates/AGENTS.template.md`

## Critical: Callback Serialization Pattern

**The most common mistake when building tools is passing function references as callback arguments.** This causes serialization errors because functions cannot be serialized across worker boundaries.

### ❌ WRONG - Passing Function as Callback Argument

```typescript
async startSync<TCallback extends Function>(
  authToken: string,
  projectId: string,
  callback: TCallback,  // User-provided callback function
  options?: SyncOptions,
  ...extraArgs: any[]
): Promise<void> {
  // ...setup code...

  // ❌ WRONG: Passing the callback function as an argument
  await this.callback(
    this.syncBatch,
    authToken,
    projectId,
    callback,      // ← Function reference - NOT SERIALIZABLE!
    options,
    ...extraArgs   // ← May contain functions - NOT SERIALIZABLE!
  );
}

async syncBatch(
  args: any,
  authToken: string,
  projectId: string,
  callback: Function,  // ← Receives function (won't work)
  options?: SyncOptions,
  ...extraArgs: any[]
): Promise<void> {
  // ❌ WRONG: Direct function call
  await (callback as any)(result, ...extraArgs);
}
```

**Error you'll see:**

```
Error: Cannot create callback args for function "syncBatch":
Found function at path "value[2]"
```

### ✅ CORRECT - Store Token, Pass Primitives

```typescript
async startSync<TCallback extends Function>(
  authToken: string,
  projectId: string,
  callback: TCallback,  // User-provided callback function
  options?: SyncOptions,
  ...extraArgs: any[]
): Promise<void> {
  // Step 1: Create callback token and STORE it
  const callbackToken = await this.tools.callbacks.createFromParent(
    callback,
    ...extraArgs
  );
  await this.set(`callback_${projectId}`, callbackToken);

  // Step 2: Pass ONLY serializable values (no functions!)
  await this.callback(
    this.syncBatch,
    authToken,
    projectId,
    options  // Only primitives/objects, NO functions
  );
}

async syncBatch(
  args: any,
  authToken: string,
  projectId: string,
  options?: SyncOptions
): Promise<void> {
  // Step 3: Retrieve callback token from storage
  const callbackToken = await this.get<Callback>(`callback_${projectId}`);
  if (!callbackToken) {
    throw new Error(`Callback token not found for project ${projectId}`);
  }

  // Step 4: Execute callback using callbacks.run()
  await this.tools.callbacks.run(callbackToken, result);
}
```

### Why This Pattern?

1. **Callbacks cross RPC boundaries** between worker instances
2. **Only serializable values** can pass through: strings, numbers, booleans, objects, arrays
3. **Functions are NOT serializable** - they must be converted to callback tokens
4. **Callback tokens are strings** - fully serializable and persistent across worker restarts
5. **Validation catches mistakes** - the system validates all arguments before storage

## Study These Examples

### ✅ Correct Patterns

- **Google Calendar**: `google-calendar/src/google-calendar.ts`

  - Lines 252-256: Creates and stores callback token
  - Lines 282-290: Passes only primitives to `this.callback()`
  - Lines 501-574: Retrieves token and uses `callbacks.run()`

- **Google Contacts**: `google-contacts/src/google-contacts.ts`

  - Lines 178-182: Creates and stores callback token
  - Lines 341-342, 396-397: Only passes primitives

- **Linear** (recently fixed): `linear/src/linear.ts`
  - Follows the same pattern as above

### Pattern Summary

```typescript
// 1. When receiving a callback from parent
const token = await this.tools.callbacks.createFromParent(callback, ...extraArgs);
await this.set("callback_key", token);

// 2. When creating internal callbacks
const token = await this.callback(this.methodName, arg1, arg2);  // Only primitives!
await this.runTask(token);

// 3. When executing stored callbacks
const token = await this.get<Callback>("callback_key");
await this.tools.callbacks.run(token, ...args);
```

## Serializable vs Non-Serializable Values

### ✅ Safe to Pass to `this.callback()` or `this.set()`

- Strings: `"hello"`, `authToken`
- Numbers: `123`, `batchNumber`
- Booleans: `true`, `false`
- null: `null`
- Objects: `{ key: "value" }`, `options`
- Arrays: `[1, 2, 3]`, `["a", "b"]`
- Dates (serialized as ISO strings): `new Date()`
- Callback tokens: `token` (returned from `this.callback()`)

### ❌ NOT Serializable

- Functions: `callback`, `this.method`, `() => {}`
- undefined: `undefined` (use `null` instead)
- Symbols: `Symbol("foo")`
- RPC stubs: Function references across worker boundaries
- Circular references: Objects referencing themselves

## Critical: Callback Backward Compatibility

**IMPORTANT:** All callbacks automatically upgrade to new twist/tool versions when a new version is deployed. You **MUST** maintain backward compatibility in ALL callback methods to prevent breaking existing callbacks.

### Backward Compatibility Rules

- ❌ **DON'T** change function signatures (remove/reorder parameters, change types)
- ❌ **DON'T** change callback signatures passed to `createFromParent()`
- ✅ **DO** add optional parameters at the end
- ✅ **DO** use version guards for behavioral changes
- ✅ **DO** handle both old and new data formats

### What Callbacks Auto-Upgrade?

All callbacks automatically upgrade to the new twist version:
- **Webhook handlers** (onWebhook, onCalendarWebhook, etc.)
- **Batch processing callbacks** (syncBatch, processBatch, etc.)
- **Scheduled callbacks** (renewWatch, cleanupExpired, etc.)
- **Tool→Twist callbacks** (onEvent, handleActivity, etc.)
- **Internal tool callbacks** (any method called via `this.callback()`)

### Examples: Good and Bad Practices

```typescript
// v1.0 - Original
async syncBatch(batchNumber: number, authToken: string, calendarId: string) {
  // Sync logic
}

// v1.1 - ✅ GOOD: Optional parameter added at the end
async syncBatch(
  batchNumber: number,
  authToken: string,
  calendarId: string,
  initialSync?: boolean  // New optional parameter
) {
  const isInitial = initialSync ?? true; // Safe default
  // Sync logic with initialSync support
}

// v2.0 - ❌ BAD: Breaking change
async syncBatch(options: SyncOptions) {  // Completely changed signature!
  // Existing batch callbacks will fail when they pass (number, string, string)
}

// v2.0 - ✅ GOOD: Handle both old and new signatures
async syncBatch(
  batchNumberOrOptions: number | SyncOptions,
  authToken?: string,
  calendarId?: string,
  initialSync?: boolean
) {
  let options: SyncOptions;

  if (typeof batchNumberOrOptions === "number") {
    // Old version - reconstruct options from individual parameters
    options = {
      batchNumber: batchNumberOrOptions,
      authToken: authToken!,
      calendarId: calendarId!,
      initialSync,
    };
  } else {
    // New version - use options object directly
    options = batchNumberOrOptions;
  }

  // Sync logic using options
}
```

### Handling Breaking Changes

If you **must** make a breaking change, implement migration logic in the `upgrade()` hook:

```typescript
async upgrade(oldVersion: string, newVersion: string) {
  if (oldVersion === "1.0" && newVersion === "2.0") {
    // Get all in-progress syncs and recreate callbacks with new signature
    const syncs = await this.get<SyncState[]>("active_syncs");

    for (const sync of syncs) {
      // Stop old sync
      await this.stopSync(sync.authToken, sync.calendarId);

      // Restart with new callback signature
      await this.startSync({
        authToken: sync.authToken,
        calendarId: sync.calendarId,
      }, this.onEvent);
    }
  }
}
```

**Note:** Users will need to uninstall and reinstall the twist/tool if breaking changes aren't properly migrated.

## Tool Development Checklist

Building a tool? Follow this checklist:

- [ ] Extend `Tool<YourTool>` from `@plotday/twister/tool`
- [ ] Declare dependencies in `build()` method
- [ ] Store auth tokens with `this.set()`
- [ ] **Convert user callbacks to tokens** with `createFromParent()`
- [ ] **Store callback tokens**, don't pass them as arguments
- [ ] **Pass only serializable values** to `this.callback()`
- [ ] Retrieve tokens with `this.get()` and execute with `callbacks.run()`
- [ ] Use batch processing for long operations - break loops into chunks to stay under ~1000 requests per execution
- [ ] Size batches appropriately - calculate requests per item to determine safe batch size
- [ ] Use `this.runTask()` to create new executions with fresh request limits
- [ ] Clean up stored state and callbacks in lifecycle methods
- [ ] **Per-user auth for write-backs**: Try `actorId` as `authToken` first, fall back to installer's token
- [ ] **Private auth activities**: Set `private: true` and add `mentions: [{ id: context.actor.id }]` in `activate()`

## Common Tool Pitfalls

1. **❌ Passing functions to `this.callback()`** - Convert to tokens first!
2. **❌ Storing functions with `this.set()`** - Convert to tokens first!
3. **❌ Not validating callback token exists** - Always check before `callbacks.run()`
4. **❌ Forgetting to store the callback token** - Store it immediately after creating
5. **❌ Passing undefined instead of null** - Use `null` for optional values
6. **❌ Not breaking loops into batches** - Each execution has ~1000 request limit; use `runTask()` for fresh limits
7. **❌ Using installer auth for all write-backs** - In multi-user priorities, try the acting user's credentials first (`note.author.id` as authToken) before falling back to installer auth
8. **❌ Non-private auth activities** - Auth activities from `activate()` should be `private: true` with mentions so only the installing user sees them
9. **❌ Two-way sync without metadata correlation** - When pushing Plot items to an external system, embed the Plot ID (`Activity.id` / `Note.id`) in the external item's metadata, and update `source`/`key` after creation. In webhook handlers, check metadata for the Plot ID first. This prevents duplicates from a race condition where the webhook arrives before the `source`/`key` update. See SYNC_STRATEGIES.md §6 for a full example.

---

**Remember**: When in doubt, study the working examples in `google-calendar/`, `google-contacts/`, and `linear/`.
