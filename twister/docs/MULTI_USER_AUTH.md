# Multi-User Auth

Connectors operate on threads that are often shared across users — the same Gmail thread, calendar event, or Linear issue appears as a single Plot thread for everyone involved. This guide covers the auth models and how the runtime routes per-user write-backs.

## Auth Models

| Model                       | Use case                                                       | Example                          |
| --------------------------- | -------------------------------------------------------------- | -------------------------------- |
| No auth                     | Twist doesn't need external credentials                        | Text-only twist                  |
| Individual auth (default)   | Each user connects their own account                           | Google Calendar, Gmail, Linear   |
| Shared auth (`shared: true`)| One credential, entered by the installer, used workspace-wide  | Slack bot token, workspace API key |

## Declaring Auth

Connectors never build their own auth UI. Declare the provider and scopes as class properties and the runtime drives the OAuth flow from the connection setup modal:

```typescript
class LinearConnector extends Connector<LinearConnector> {
  readonly provider = AuthProvider.Linear;
  readonly scopes = ["read", "write"];
  // ...
}
```

Key points:

- `shared = true` — one credential is shared across all users in the workspace, entered once by the installer. The default (`false`) is per-user auth: each user connects their own account.
- `keyOption` — set to the name of a `secure: true` Options field to use API-key auth instead of OAuth. For individual connectors the key is stored per-user.
- Read tokens with `this.tools.integrations.get(channelId)` — returns the token of the user who enabled sync on that channel, or `null` if the channel isn't enabled or the token is invalid.

## Per-User Auth for Write-Backs

When a user acts on a shared thread — replying with a note, adding a reaction, changing a to-do or RSVP status — the runtime dispatches the change to **the acting user's own connector instance**, which is the only instance holding their OAuth token. Your callback (`onNoteCreated`, `onNoteUpdated`, `onNoteReactionChanged`, `onThreadToDo`, …) already runs under the acting user's auth: fetch the token through the connector's normal path and the external write is attributed to them automatically. No actor-switching step is required.

```typescript
async onNoteCreated(note: Note, thread: Thread): Promise<NoteWriteBackResult | void> {
  // This instance belongs to the user who wrote the note, so this token is theirs.
  const token = await this.tools.integrations.get(thread.meta?.channelId as string);
  if (!token) return;

  const comment = await this.addIssueComment(token, thread.meta, note.content ?? "");
  // Returning { key, externalContent } lets the runtime set note.key AND
  // record the sync baseline so future re-syncs preserve Plot's markdown.
  return { key: `comment-${comment.id}`, externalContent: comment.body };
}
```

### When the Acting User Has No Connection

If the acting user has no connection of this type, the change is saved in Plot but no write-back dispatch fires — there is no connector instance with their credentials to deliver it to. The thread stays consistent in Plot; the external system simply doesn't receive that user's change.

This also means connectors don't need a "fall back to the installer's credentials" code path: dispatch routing already guarantees a write-back callback only runs with the acting user's own credentials.

## Cross-User Thread Sharing

Auth is per-user, but the synced data converges: when several users' connectors sync the same external item (the same `source`), they share a single Plot thread. Each user gains access when their own connector instance syncs the item — populating `thread.contacts` with recipients does not by itself admit them. See `connectors/AGENTS.md` → "`source` — idempotency + cross-user dedup" and "Attestation-based visibility" for the full contract.
