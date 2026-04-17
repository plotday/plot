# Callback dispatch (platform internals)

This doc is for maintainers of the twist runtime in the API worker. It is
**not** part of the public SDK and must not be linked from or duplicated into
`public/` — connector and twist authors are not expected to know that Plot
runs on Cloudflare Workers or that RPC boundaries exist.

## The rule

**Never invoke a callback RPC stub directly.** When a twist or connector
passes a method reference to a built-in tool (e.g. `this.tools.integrations
.actAs(provider, actorId, threadId, this.syncActorRSVP, ...args)`), that
reference crosses the Cloudflare Workers RPC boundary and arrives as an
`Rpc.Stub<Function>`. Calling the stub executes only the function body —
the enclosing class instance is not reachable, so `this.X` inside the
method resolves to `undefined` for any sibling method or private field.

Symptom when violated: `TypeError: this.X is not a function`, thrown from
inside the twist worker, wrapped as a TwistError.

## The canonical helper

`workers/api/src/twist/invoke-callback.ts` — `invokeCallback(callbacks,
twistInstanceId, callback, path, extraArgs, ...args)`.

It resolves the function name with `getRpcFunctionName`, registers a
one-shot entry in `CallbacksState`, and invokes it via
`callbacks.callCallback(token, ...args)`. That path rebuilds the twist in
the twist worker (`entrypoint.ts` → `buildTwist(...)`) and dispatches by
name with `method.call(twist, ...)` — giving the method full access to its
class.

Use this helper for any place in the API worker that receives a callback
from a twist/connector and wants to run it. The token-based paths already
in the codebase — `Callbacks.create()` + `CallbacksState.callCallback()`,
`Tasks.runTask()`, `Network.createWebhook()` — are all safe variants of
the same pattern.

## Safe patterns that already exist

These do the right thing and do not need touching:

- `TwistEntrypoint.callCallback(...)` (`entrypoint.ts`) — runs inside the
  twist worker, calls `method.call(twist, ...)` after `buildTwist(...)`.
- `TwistEntrypoint.dispatchToTool(...)` (`entrypoint.ts`) — same; handles
  both `sourceMethod` and `optionPath` dispatch shapes with explicit
  context binding.
- The `callbacks.run()` proxy installed in `ToolShed.waitForReady()`
  (`entrypoint.ts`) — resolves the token locally via `resolve()` and calls
  on the already-built tool tree, so `this` binding is preserved.
- `CallbacksState.callCallback(token, ...)` (`state/callbacks.ts`) —
  rebuilds the twist via `twistFactory` and dispatches through
  `twistWrapper.callCallback`.

## Unsafe patterns to watch for

Grep for these when reviewing platform changes:

- `await callback(` / `await cb(` / `await stub(` where the identifier
  came from an RPC method parameter.
- `.bind(` or property access on an RPC stub — stubs don't expose class
  methods; property access like `stub.otherMethod` is always undefined.

Every such site must either (a) use `invokeCallback` from this directory,
or (b) route through the existing token-based dispatch APIs.

## Historical note

The bug that motivated this helper: `Integrations.actAs()` had a fast path
that called `await callback(token, ...extraArgs)` directly when the actor
already had a valid token. The slow path (no token) already did the right
thing by registering a callback via `this.callbacks.create({...,
functionName})` and invoking it post-auth through
`CallbacksState.callCallback`. The fast path was the only outlier, and it
manifested as `TypeError: this.updateEventRSVPWithApi is not a function`
when the Google Calendar connector's `syncActorRSVP` tried to call its own
private helper. The fix was to route both paths through `invokeCallback`.
