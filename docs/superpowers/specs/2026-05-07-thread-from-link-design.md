# Create thread from a single link

## Goal

Allow creating a new thread that contains only a link — no note body. Submit
must enable as soon as a link is present (link button, link modal, or share
intent), and the new thread should adopt the link's page title and favicon
as its title and icon. The share intent from another app is the primary use
case.

## Current state

- `apps/plot/lib/widget/note_editor.dart:1060` disables the submit button on
  `NewThreadPage` when the editor body is empty
  (`enabled: !_saving && !_isEmpty`). Existing-thread mode at line 949–951
  already allows actions:
  `(!_isEmpty || (widget.draft.actions?.isNotEmpty ?? false))`.
- `AddLink` (`lib/command/add_link.dart`) builds an
  `ExternalUserAction(title, url)` from `LinkModal.open` and drops the
  favicon that the modal already fetched via `fetchUrlMetadata`.
- `NewThreadPage._applyQueryParametersToDraft` adds the share-intent URL as
  `ExternalUserAction(title: sharedUrl, url: sharedUrl)` with no metadata
  fetch — the title is the raw URL.
- `AddThreadWithLink` (`lib/command/thread.dart:375`) already exists and is
  unused. It sets `thread.title` to the link title, `thread.icon` to the
  favicon, calls `priorityBloc.add`, and creates a thread-level `LinkRow`.

## Plan

### 1. Persist favicon on `ExternalUserAction`

`lib/store/user_action.dart`: add an optional `String? favicon` field.
`fromJson` reads `json['favicon'] as String?` (back-compat for old rows
without the field). `toJson` only emits the key when non-null. Update
`props` for equality.

### 2. Pass favicon through `AddLink`

`lib/command/add_link.dart`: when constructing the `ExternalUserAction` from
a `LinkModalResult.link`, include `favicon: result.favicon`.

### 3. Enable submit when the draft has an external link

`lib/widget/note_editor.dart` `_buildNewThreadBottomBar`, line 1060: change
`enabled: !_saving && !_isEmpty` to also enable on `ExternalUserAction`:

```dart
enabled: !_saving &&
    (!_isEmpty ||
        (widget.draft.actions
                ?.whereType<ExternalUserAction>()
                .isNotEmpty ??
            false)),
```

Limited to `ExternalUserAction` (not all action types). Body-less submit
routes through `AddThreadWithLink`, which doesn't save a Note — so file
attachments and connector "create new" actions, which piggyback on a
non-empty Note, would be silently dropped. Those still require a body, as
they did before.

### 4. Route empty-body + link through `AddThreadWithLink`

`lib/widget/note_editor.dart` `_onNewThreadSubmitted`: before calling
`finalizeThreadDraft`, check for the link-only case:
- `body.trim().isEmpty`
- the draft note has at least one `ExternalUserAction`

Take the first `ExternalUserAction` and dispatch
`AddThreadWithLink(linkUrl: a.url, linkTitle: a.title, linkFavicon:
a.favicon)`. The link becomes a thread-level `LinkRow` (matches Plot's
existing model — see `_ThreadLinkRow` rendering in `page/thread.dart`); no
`Note` is created.

For body non-empty, or no `ExternalUserAction`, take the existing path
through `AddThreadWithNote`.

### 5. Preserve user-set title/icon in `AddThreadWithLink`

`lib/command/thread.dart`: in `AddThreadWithLink.run`, only override
`draft.title` if it is null/empty, and only override `draft.icon` if it is
null/empty. A user who set the title via the title chip or picked a type via
the type chip keeps their choice.

### 6. Fetch metadata for share-intent URLs

`lib/page/new_thread.dart` `_applyQueryParametersToDraft`: when a
`sharedUrl` is provided:
- Add the `ExternalUserAction` immediately with `title: sharedUrl, url:
  sharedUrl` so the chip is visible even on slow networks (existing
  behavior).
- Fire-and-forget `fetchUrlMetadata(sharedUrl)` afterwards. When it
  resolves, find the matching action in the current draft (by URL match,
  not identity — the draft may have been mutated meanwhile) and replace it
  with `ExternalUserAction(title: meta.title ?? sharedUrl, url: sharedUrl,
  favicon: meta.favicon)`.

If the user submits before the metadata fetch returns,
`AddThreadWithLink` falls back to `linkTitle ?? linkUrl` for the title and
`'link'` for the icon. Thread saves successfully; metadata can be backfilled
later by sync.

## Out of scope

- Body + link: existing path (note saved with `ExternalUserAction`).
- Multiple links: use the first.
- `CreateLinkUserAction` (connector "create new"): existing path; not
  treated as "a link" for this feature.
- Server-side metadata enrichment for the resulting `LinkRow`: existing
  link sync behavior applies.

## Verification

- `flutter analyze` clean across the app.
- Manual: paste-share a URL on iOS/Android into the new-thread page →
  submit button is enabled immediately; the link chip's title updates once
  metadata returns; submitting creates a thread titled with the page title
  and an icon set to the favicon.
- Manual: in-app link button → add link → empty body → submit creates the
  same shape.
- Manual: in-app link button → type a body → submit takes the existing
  note path (note saved with the link as `ExternalUserAction`).
- Manual: set a title via the title chip, then add a link → submit
  preserves the user's title.
