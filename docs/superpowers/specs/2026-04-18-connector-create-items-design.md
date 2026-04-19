# Create new items in external systems via connectors

## Summary

Let Plot users create new items (e.g. a Linear issue, a Google Calendar
event) in external systems through connectors. The user initiates creation
from the Add link modal on NewThreadPage; when the thread is synced, the
API dispatches to the connector which creates the item and returns a Link
that the platform attaches to the thread.

## Twister SDK changes (`public/twister/`)

### `LinkTypeConfig.statuses[].createDefault`

Extend each status entry in `LinkTypeConfig` (`src/tools/integrations.ts`)
with an optional marker indicating it is the default status for newly
created items:

```ts
statuses?: Array<{
  status: string;
  label: string;
  tag?: Tag;
  done?: boolean;
  todo?: boolean;
  /** Default status applied to items created from Plot. At most one per type. */
  createDefault?: boolean;
}>;
```

No `create` flag on `LinkTypeConfig` itself — a link type opts in simply
by having one status with `createDefault: true`. This avoids an invalid
state where `create: true` but no default status is declared.

### `Connector.onCreateLink`

Add one optional callback to the `Connector` base class in
`src/connector.ts`. It is stateless with respect to threads — connectors
stay thread-agnostic.

```ts
/**
 * Called when a user creates a thread in Plot that should create a new
 * item in this connector's external system. The returned link is attached
 * to the originating thread by the platform.
 *
 * @param draft - Fields captured in Plot for the new item.
 * @returns The Link (with optional notes) to attach, or null to abort.
 */
onCreateLink(draft: CreateLinkDraft): Promise<NewLinkWithNotes | null>;

export type CreateLinkDraft = {
  /** Channel (account + resource) the item belongs to. */
  channelId: string;
  /** Link type matching a `LinkTypeConfig.type`. */
  type: string;
  /** Status the user selected. Matches `statuses[].status`. */
  status: string;
  /** Title of the originating Plot thread (post AI-title generation). */
  title: string;
  /** First note's markdown content, or null if the thread has none. */
  noteContent: string | null;
};
```

Changeset: `minor` — new feature, `Added:` category.

## API changes (`workers/api/`)

### Dispatch path

Extend `workers/api/src/twist/tools/integrations.ts` with a new
`itemType: "create_link"` dispatch shape that:

1. Calls the connector's `onCreateLink(draft)`.
2. On a non-null return, routes the returned `NewLinkWithNotes` through
   the existing `saveLink`-equivalent internal path, forcing
   `thread_id` to the originating thread (rather than creating a new
   thread as `saveLink` normally does).

### `/sync/threads` hook

In `workers/api/src/app/sync/threads.ts`, after AI title generation and
successful `upsert_thread`, inspect an optional `create_link` field on the
POST body:

```ts
body.create_link?: {
  twist_instance_id: string;
  channel_id: string;
  type: string;
  status: string;
};
```

If present and `threadData.draft !== true`, queue a `waitUntil` dispatch:

```ts
twistFactory({ env, ctx, db })({ twistInstanceId: create_link.twist_instance_id })
  .then(w => w.dispatch("Integrations", {
    itemType: "create_link",
    threadId: upsertResult.id,
    draft: {
      channelId: create_link.channel_id,
      type: create_link.type,
      status: create_link.status,
      title: threadData.title,
      noteContent: /* first note markdown */,
    },
  }));
```

First-note content is retrieved from `threadData.notes?.[0]?.content` (the
client already sends notes alongside the thread for new drafts) or by
looking up the earliest note for the thread if not present in the
request.

Errors during dispatch are captured via `tracker.captureException` but do
not fail the request — the thread was already persisted.

## Flutter changes (`apps/plot/`)

### `CreateLinkUserAction`

New variant in `lib/store/user_action.dart` — serializes alongside other
`UserAction`s on `Note.actions`:

```dart
class CreateLinkUserAction extends UserAction {
  final Uuid twistInstanceId;
  final String channelId;
  final String type;
  final String status;           // mutable via status selector
  final String accountName;      // denormalized for display only
  final String linkTypeLabel;    // denormalized for display only
  final String twistName;        // denormalized for display only
  final String? logo;            // denormalized for display only
  final String? logoDark;
  // toJson / fromJson / props
}
```

Display fields are denormalized so the draft row renders without any
async lookups. Type-of-truth for status/type/etc. on resync is still the
`TwistInstance` / `Channel` row in the store.

### `LinkModal` changes (`lib/widget/link_input.dart`)

1. Load: `final createTargets = await _loadCreateTargets();` — one per
   `(TwistInstance, Channel?, LinkTypeConfig)` tuple where the config has
   a status with `createDefault: true`. Channel-level link types override
   twist-level ones (matches existing `Link.getTypeConfig` resolution).
2. Extend `_LinkItem` with a `createExternal` variant carrying the tuple.
3. Build result groups:
   - Empty search → single group `title: 'Create new'` containing all
     create targets.
   - Non-empty search → filter create targets where `linkTypeLabel`,
     `twistName`, or `accountName` contains the search string (case
     insensitive); prepend a `Create new` group if any match. Existing
     link-search groups follow.
4. Row rendering: logo from `LinkTypeConfig` (dark-aware via
   `logoForBrightness`), title `Create new $twistName $linkTypeLabel`,
   subtitle `$accountName`.
5. Extend `LinkModalResult` with a `createExternal` constructor.

### `AddLink` command (`lib/command/add_link.dart`)

On `createExternal`, append a `CreateLinkUserAction` to the current
actions list (same pattern as the existing `ExternalUserAction` branch).
Pre-fill `status` with the `createDefault: true` status. Only one
`CreateLinkUserAction` may exist per thread at a time — if one already
exists it is replaced.

### `NoteEditor` changes (`lib/widget/note_editor.dart`)

`_buildAttachmentRow` gains a branch for `CreateLinkUserAction`:

- Leading: `LogoImage(url: logo)` (dark-aware), size 16.
- Title: `Create new $twistName $linkTypeLabel` — left-aligned, truncated.
- Subtitle-ish: `$accountName` rendered muted after the title.
- Trailing (before the existing X remove button): ghost-variant `FButton`
  showing the current `statusLabel` (plus a small chevron) that opens
  `SelectModal<LinkStatus>` over the link type's declared statuses.
  Selecting updates the action in place via `onDraftChanged`.

The create row is always rendered first in the attachment list so the
"new link being created" stays prominent.

### Sync request payload

`Note.toBase` in the drift store attaches the action as part of the
`actions` JSON (nothing special needed — free-form list). The thread
sync path (`ThreadsBase.toBase` or the `POST /sync/threads` body
assembly) extracts the first `CreateLinkUserAction` on the draft note,
emits it as `body.create_link`, and does **not** include it in the
`actions` array sent with the note — the platform will replace it with
a real link via normal sync once the connector responds.

Until the real link arrives, the local drift row keeps the
`CreateLinkUserAction`; once the synced link appears (threadId match,
type + channelId match), the local pruning logic strips the action.

## Build sequence

1. Twister SDK changes + changeset (`LinkTypeConfig`, `Connector`).
2. API dispatch path + `/sync/threads` hook.
3. Flutter `CreateLinkUserAction` + store serialization.
4. Flutter `LinkModal` + `AddLink` command.
5. Flutter `NoteEditor` row + status selector modal.
6. Opt-in proof: `public/connectors/linear/` — add `createDefault: true`
   to the `issue` "todo" status and implement `onCreateLink` creating a
   Linear issue and returning a `NewLinkWithNotes`.

## Out of scope

- Connector-defined form fields for additional creation options (future).
- More than one `CreateLinkUserAction` per thread.
- Editing the created item from Plot after it syncs back (handled
  separately by existing `onLinkUpdated`).
