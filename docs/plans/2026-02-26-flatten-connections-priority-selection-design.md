# Flatten Connections Modal + Priority Selection on Channel Enable

## Problem

1. **Bug**: When a Google Calendar channel syncs, `priority_id` is null because channels are enabled without associating a priority. The database rejects the thread insert with "priority_id must be provided".
2. **UX**: Connections require 3 modal levels to manage (ManageTwists → ManageConnections → EditSource). This should be flattened.

## Design

### Flattened Connections Modal

Replace the current `ManageConnections._buildForm()` which lists sources as buttons (requiring a click to see channels) with a flat list of all accounts across all sources, each showing their channels inline with toggles.

**Current flow:**
```
ManageTwists → [Connections] button → ManageConnections (list of sources)
  → click source → EditSource (channels + toggles + save)
```

**New flow:**
```
ManageTwists → [Connections] button → ManageConnections (flat account list + channels + save)
```

**Layout:**
```
┌─ Connections ─────────────────────────┐
│                                        │
│  Google Calendar · kris@gmail.com      │
│    ☑ Primary Calendar    → Work        │
│    ☐ Birthdays                         │
│    ☐ Holidays                          │
│                                        │
│  Slack · kris@company.com              │
│    ☑ #general           → Projects     │
│                                        │
│  [+ Add Connection]                    │
│  [Save]                                │
└────────────────────────────────────────┘
```

Each item shows: `{Source Name} · {Account Display Name}`, followed by its channels with toggles. Enabled channels show their target priority. The source name comes from the existing source data, and the account display name from the integration accounts.

### Priority Selection on Channel Enable

When a user toggles a channel ON, a sub-modal pops showing all the user's priorities. The user must select a priority before the channel is considered enabled. If they dismiss the modal without selecting, the toggle reverts to OFF.

The selected priority is stored locally in `IntegrationChanges` alongside the channel key, and sent to the API when Save is pressed.

### Data Model Changes

**`IntegrationChanges`** — add a `channelPriorities` map:
```dart
class IntegrationChanges {
  final Set<String> selectedChannels;     // "provider:channelId" keys
  final Set<String> removedAccounts;      // "provider:actorId" keys
  final Map<String, String> channelPriorities; // "provider:channelId" → priorityId
}
```

**`TwistApi.enableChannel`** — add `priorityId` parameter:
```dart
static Future<void> enableChannel({
  required String priorityTwistId,
  required String provider,
  required String channelId,
  String? priorityId,  // NEW
}) async {
  await api.post('/twist/$priorityTwistId/syncables/$provider/$channelId/enable',
    body: priorityId != null ? {'priorityId': priorityId} : null,
  );
}
```

**`SaveSource`** — now scoped per-source but called for each source in the flat view. Pass `channelPriorities` when enabling.

### Multi-Source Save

Since the flat view shows channels from multiple sources, `ManageConnections` needs to track changes per source and save each source independently. The `IntegrationChanges` is expanded to include the `priorityTwistId` for each channel:

```dart
// Key format: "priorityTwistId:provider:channelId"
// This allows grouping by priorityTwistId at save time
```

Alternatively, maintain a `Map<String, IntegrationChanges>` keyed by `priorityTwistId`.

### Files to Modify

1. **`apps/plot/lib/widget/twist_integrations.dart`** — Update `IntegrationChanges` to include `channelPriorities`. Update `_toggleChannel` to trigger priority picker. Show priority label next to enabled channels.

2. **`apps/plot/lib/command/twist.dart`** — Rewrite `ManageConnections._buildForm()` to fetch all sources' integrations and render flat. Update `SaveSource` to pass `priorityId` when enabling. Add priority picker command.

3. **`apps/plot/lib/api/twist_api.dart`** — Add `priorityId` parameter to `enableChannel()`.

### Priority Picker Implementation

Reuse the pattern from `MoveThreadToPriority` — a `ShowCommands` that lists all priorities and returns the selected one. When the user selects a priority, the channel toggle commits with that priority stored in `channelPriorities`.

```dart
class SelectChannelPriority extends ShowCommands {
  // Lists all priorities, returns selected priority ID via Modal.pop
}
```

### Edge Cases

- **Existing enabled channels without priority**: Show them as enabled but with a "Select priority" prompt. Save should require all enabled channels have a priority.
- **Cancel priority picker**: Revert the toggle to OFF.
- **Changing priority for already-enabled channel**: Tap the priority label to re-open the picker. Use `TwistApi.setChannelPriority()` on save.
