# Multi-User Priority Auth

Twists and tools operating in shared priorities must handle authentication for multiple users. This guide covers the patterns for per-user auth and private auth activities.

## Auth Models

| Model | Use case | Example |
|-------|----------|---------|
| No auth | Twist doesn't need external credentials | Text-only twist |
| Read-only single auth | Installer connects, synced data visible to all | Calendar sync (read) |
| Two-way per-user auth | Write-backs use the acting user's credentials | Comments, RSVP responses |

## Private Auth Activities

When a twist creates an auth activity in `activate()`, make it `private: true` and add `mentions` targeting `context.actor`. This ensures only the installing user sees the auth prompt — other priority members won't be spammed with irrelevant auth requests.

```typescript
async activate(_priority: Pick<Priority, "id">, context?: { actor: Actor }) {
  const authLink = await this.tools.myTool.requestAuth(this.onAuthComplete, "provider");

  await this.tools.plot.createActivity({
    type: ActivityType.Action,
    title: "Connect your account",
    private: true,
    notes: [{
      content: "Connect to get started.",
      links: [authLink],
      ...(context?.actor ? { mentions: [{ id: context.actor.id }] } : {}),
    }],
  });
}
```

Key points:
- `private: true` — only the author and mentioned users can see the activity
- `context?.actor` — the user who installed the twist (available from the SDK)
- Always guard with `?.` since `context` is optional for backward compatibility

## Per-User Auth for Write-Backs

When a twist needs to write back to an external system (e.g., posting a comment on a Linear issue), it should use the acting user's credentials when available.

### Pattern: Try Actor First, Fall Back to Installer

The simplest approach passes the actor's ID as the `authToken` parameter. The tool's `getClient()` method will look it up via `integrations.get(provider, actorId)`:

```typescript
private async onNoteCreated(note: Note): Promise<void> {
  const provider = activity.meta?.provider;
  const tool = this.getProviderTool(provider);

  // Try actor's credentials first, then installer's
  const actorId = note.author.id as string;
  const installerAuthToken = await this.getAuthToken(provider);

  const authTokensToTry = [
    actorId,
    ...(installerAuthToken && installerAuthToken !== actorId
      ? [installerAuthToken]
      : []),
  ];

  for (const authToken of authTokensToTry) {
    try {
      await tool.addIssueComment(authToken, activity.meta, note.content, note.id);
      return; // Success
    } catch {
      continue; // Try next token
    }
  }
}
```

### When Actor ID Is Not Available

For callbacks like `onActivityUpdated` where the acting user's ID is not included in the callback signature, continue using the installer's stored auth token. This is acceptable because:

- Activity field updates (title, assignee, done) are less user-specific
- The change itself is the same regardless of who made it
- Per-user auth is most valuable for user-attributed actions like comments

### How Tools Resolve Auth Tokens

Tools with per-user auth support resolve tokens in their `getClient()` method:

1. Try `integrations.get(provider, authToken as ActorId)` — looks up per-actor credentials
2. Fall back to legacy token lookup if the actor has no credentials
3. Throw if neither works (caller catches and tries the next token)

## On-Demand Auth Requests

When a user without credentials performs a write-back action, you can optionally create a private auth-request activity prompting them to connect:

```typescript
// Create auth request for a specific actor
const authLink = await tool.requestAuth(this.onActorAuth, actorId);

await this.tools.plot.createActivity({
  type: ActivityType.Action,
  title: "Connect to sync your changes",
  private: true,
  source: `auth:${actorId}`, // Dedup: one auth request per user
  notes: [{
    content: "Connect your account so your changes appear under your name.",
    links: [authLink],
    mentions: [{ id: actorId as ActorId }],
  }],
});
```

This is optional — the simpler approach is to silently fall back to the installer's credentials.
