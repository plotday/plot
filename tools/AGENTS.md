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

## Tool Development Checklist

Building a tool? Follow this checklist:

- [ ] Extend `Tool<YourTool>` from `@plotday/twister/tool`
- [ ] Declare dependencies in `build()` method
- [ ] Store auth tokens with `this.set()`
- [ ] **Convert user callbacks to tokens** with `createFromParent()`
- [ ] **Store callback tokens**, don't pass them as arguments
- [ ] **Pass only serializable values** to `this.callback()`
- [ ] Retrieve tokens with `this.get()` and execute with `callbacks.run()`
- [ ] Use batch processing for long operations (see `../twister/cli/templates/AGENTS.template.md`)
- [ ] Clean up stored state and callbacks in lifecycle methods

## Common Tool Pitfalls

1. **❌ Passing functions to `this.callback()`** - Convert to tokens first!
2. **❌ Storing functions with `this.set()`** - Convert to tokens first!
3. **❌ Not validating callback token exists** - Always check before `callbacks.run()`
4. **❌ Forgetting to store the callback token** - Store it immediately after creating
5. **❌ Passing undefined instead of null** - Use `null` for optional values

---

**Remember**: When in doubt, study the working examples in `google-calendar/`, `google-contacts/`, and `linear/`.
