# Per–link-type gating of "Add link" / "Attach file" in NoteEditor

**Date:** 2026-06-02
**Status:** Approved

## Problem

The NoteEditor bottom bar always shows "Add link" and "Attach file" buttons,
regardless of whether the note's underlying source can actually carry a link or
a file attachment when the note is forwarded back to that source on reply.

Some sources cannot accept these:

- **Google Tasks** — accepts neither links nor file attachments.
- **Gmail** — accepts file attachments, but not links (we would have to append
  them to the message body, which is not implemented).

**Private Plot notes always support both**, because they live only on Plot and
are never forwarded to an external source.

## Goal

Show "Add link" only for link types that can carry a link, and "Attach file"
only for link types that can carry a file attachment. Private Plot notes
(no link type) keep both.

## Decisions (from brainstorming)

- **Default is opt-in / OFF.** A link type carries a link or a file only if its
  connector explicitly declares support. Undeclared connectors get neither
  button. (`null` config = private Plot note = both, always.)
- **Full audit.** All 24 connectors are audited and declared in this change, so
  connectors that genuinely forward files/links keep their buttons. Truth comes
  from each connector's reply/send code, not assumptions.
- **The entire "Add link" button** (including the "Create new…" picker) is gated
  on `supportsLinks` when on a connector thread. Only private Plot notes show the
  full picker unconditionally.

## Design

### 1. Capability flags (the contract)

Add two opt-in boolean flags to `LinkTypeConfig`, mirroring the existing
`supportsAssignee` / `supportsContactChanges` pattern (both default `false`):

- `supportsLinks` — source can carry a link (pasted URL or connector-created
  item) on a note/reply.
- `supportsFileAttachments` — source can carry an uploaded file on a note/reply.

Defined in two places:

- **Twister** `public/twister/src/tools/integrations.ts` — add to the
  `LinkTypeConfig` type. Requires a changeset (`minor`, `Added:`).
- **Dart** `apps/plot/lib/store/link.dart` — add the two `bool` fields (default
  `false`) and parse them in `LinkTypeConfig.fromJson` with camelCase +
  snake_case fallbacks (`supportsLinks` / `supports_links`,
  `supportsFileAttachments` / `supports_file_attachments`).

**No DB schema change.** Link type configs ride the existing `channel.link_types`
jsonb column (`workers/api/src/twist/tools/integrations.ts:700`,
`JSON.stringify(linkTypes)`), which is passed through to Flutter verbatim. New
jsonb keys propagate automatically.

### 2. Flutter gating (the behavior)

In `apps/plot/lib/widget/note_editor.dart`, resolve the active `LinkTypeConfig`
for the current editing context and gate the two buttons:

- **Note mode** (reply to an existing thread): use
  `ThreadBloc.state.primaryLinkTypeConfig` (the first link's config — the
  established pattern at `thread_state.dart:54`).
- **New-thread compose mode**: use the selected `CreateLinkUserAction`'s
  link-type config (the connector being composed into). When no connector target
  is selected (plain Plot thread), the config is `null`.
- **`null` config → private Plot note → both buttons allowed.**

Gating rule for a resolved config `cfg`:

- "Add link" button **and** its `Cmd+Shift+L` shortcut: shown only if
  `cfg == null || cfg.supportsLinks`.
- "Attach file" button: shown only if `cfg == null || cfg.supportsFileAttachments`.

Applied in both bottom bars (note mode + new-thread mode) and in the
`_shortcutAddLink` handler.

### 3. Connector audit (completed) + minimal edits

All connectors in `public/connectors/*` were audited by reading each one's
reply/send path. A flag is set `true` only where the connector **actually
forwards** that action type to the source.

**Result — only file-attachment forwarding exists today; no connector forwards
the "Add link" (`ExternalUserAction`) output.** URLs typed into the markdown body
are sent as body text, which is *not* the "Add link" attachment (it is the
"special handling" caveat called out for Gmail), so it does not count as
`supportsLinks`.

| Connector | Reply path | Forwards files | Forwards link action | Flags to set |
|-----------|-----------|----------------|----------------------|--------------|
| gmail | reply w/ attachments (`gmail.ts:1527-1544`) | YES | no | `supportsFileAttachments: true` |
| slack | postMessage + upload (`slack.ts:1212-1246`) | YES | no | `supportsFileAttachments: true` |
| linear | addIssueComment + fileUpload (`linear.ts:800-897`) | YES | no | `supportsFileAttachments: true` |
| attio | onNoteCreated, plaintext only | no | no | — (default OFF) |
| github | onNoteCreated, markdown body only | no | no | — |
| google-chat | onNoteCreated, text only | no | no | — |
| google-drive | comments, plaintext only | no | no | — |
| jira | addIssueComment, body only | no | no | — |
| notion | addComment, body only | no | no | — |
| todoist | createComment, plaintext only | no | no | — |
| ms-teams | sendChatMessage/Reply, body only | no | no | — |
| linkedin-messaging | sendMessage, text only | no | no | — |
| google-tasks | onCreateLink only (no reply path) | no | no | — |
| airtable, asana, fellow, granola | read-only sync (no reply path) | no | no | — |
| apple/google/outlook calendar | read-only / RSVP write-back only | no | no | — |
| google-contacts, posthog | read-only, no linkTypes | no | no | — |

**Decision: minimal edits.** Add `supportsFileAttachments: true` to the
`linkTypes` declaration in exactly three connectors — gmail, slack, linear. The
other 21 are left untouched; default-OFF already yields the correct "neither."
`supportsLinks` is set nowhere (no connector qualifies yet).

Declaration sites to edit:
- `public/connectors/gmail/src/gmail.ts:200` (type `"email"`)
- `public/connectors/slack/src/slack.ts:100` (type `"message"`)
- `public/connectors/linear/src/linear.ts:72` (type `"issue"`)

This is a public-submodule change (separate PR) and needs the Twister changeset
from step 1.

## Edge cases / notes

- **Multi-link threads**: use the primary (first) link's config — the established
  pattern.
- **Stale stored configs**: channel rows synced before this change lack the new
  jsonb keys → parsed as `false` → buttons hidden until the connector
  re-registers locally. Safe failure mode (hidden, not broken), consistent with
  opt-in. Re-running a connector locally refreshes its `link_types`.
- **Local only.** Connectors run locally; no deploy. Production rollout (connector
  redeploy to refresh stored `link_types`) is out of scope.

## Out of scope

- Appending links to Gmail message bodies (would let Gmail set `supportsLinks`).
- Any UI to surface *why* a button is hidden.
- Production deployment / connector redeploy.
