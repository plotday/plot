# Thread Sharing Models

## Context

Plot currently treats every thread as if it has a single, thread-level
sharing roster (`thread.contacts` + `thread.groups`). That model is
correct for native Plot threads and Slack DMs, but it misrepresents two
other common shapes:

- **Channel-level sharing** — every thread in a Slack channel or Linear
  project is implicitly shared with the channel/project members. The
  per-thread contact list is irrelevant (or wrong: it would have to
  enumerate hundreds of members).
- **Message-level sharing** — every message in an email thread carries
  its own To/Cc/Bcc set. The "thread" is a union of all messages'
  recipients, and individual notes can diverge from that union (private
  replies, Bcc).

The schema already has the pieces (`note.access_contacts` for per-note
visibility, `channel.title` for channel display, `LinkTypeConfig` per
connector). What's missing is an explicit declaration of which model
applies to a given thread, and UI that signifies the model to the user
without making the easy case harder.

A separate, in-flight plan reworks the contact-selection modal to be
role-aware (To/Cc/Bcc, Required/Optional):
`/Users/kris.braun/.claude/plans/rethink-the-modal-used-abundant-wand.md`.
This design extends that modal for message-mode threads; it does not
replace it.

## Goals

1. Make Plot capable of representing all three sharing models from
   connector data.
2. Signify the active sharing model in the thread UI so users can tell
   at a glance.
3. Surface per-note divergence (private replies, Bcc, late additions)
   without cluttering the dominant case where every note matches the
   thread default.
4. Preserve dropped Plot users' privacy: a dropped participant must
   not learn that the thread continued without them, nor who was added
   later.

## Non-goals

- Allowing a user to send a one-off message to a subset *without*
  changing the thread default. Useful, but a follow-up — out of scope
  here.
- Surfacing per-contact role changes as note-level badges. Email's
  "everyone on Cc after the first reply" pattern makes role-change
  badges noisy; skipped for now.
- Channel detail surfaces (member list, settings) for channel-mode
  threads. Tapping the channel title is a no-op in this design;
  channel detail UI is not on the roadmap yet.
- Cross-thread "subset" memory. The heuristic for non-Plot inbound
  edits runs per-message, not across the thread's history.

## Sharing models

```
SharingModel = "thread" | "channel" | "message"
```

- **thread**: one roster for the whole thread; all notes share it.
  Native Plot threads, Slack DMs, calendar events.
- **channel**: visibility is the external channel's membership; the
  per-thread roster is meaningless. Slack channels, Linear projects.
- **message**: each note carries its own recipient set; the thread
  roster is the union. Email.

## Determination

A thread's sharing model is **the model of its primary link** — the
earliest-created link on the thread, which is the originating source.
Threads with no link default to `"thread"` (native Plot composer).

In practice most threads have one link and resolution is unambiguous.
The multi-link case (e.g. a thread cross-posted across connectors) is
rare today; the earliest-link rule gives it a deterministic answer
that matches user intuition (the thread "is" the thing it was created
from). If multi-link threads become common, formalize a more
principled rule then.

The model is declared by the connector on `LinkTypeConfig`:

```ts
// public/twister/src/link.ts (or wherever LinkTypeConfig lives)
type SharingModel = "thread" | "channel" | "message";

type LinkTypeConfig = {
  // ...existing fields...
  sharingModel: SharingModel;
};
```

Connector declarations:

| Connector | Link type | sharingModel |
|---|---|---|
| Slack | `thread` (public/private channels) | `channel` |
| Slack | `dm` | `thread` |
| Linear | issue (in a project) | `channel` |
| Gmail | message | `message` |
| Google Calendar | event | `thread` |

`LinkTypeConfig` is already synced to the Flutter client (it drives
compose-link selection). Resolution is therefore client-side: look up
the primary link's `LinkTypeConfig.sharingModel`. No new thread column.
No view changes.

## Data invariants

### Message-mode: always-explicit `access_contacts`

For every note in a message-mode thread, `note.access_contacts` is
populated explicitly. **`NULL` is reserved for non-message-mode
threads.** This invariant unlocks three downstream behaviors with no
extra schema:

1. **Historical participant set** = `UNION(note.access_contacts)` across
   all of the thread's notes. Feeds the "Dropped" section in the
   sharing modal and the suggestion source for re-adding past
   participants.
2. **Per-viewer participant derivation** (see "Dropped Plot users"
   below) is well-defined: the viewer sees a coherent participant set
   that matches the notes they can read.
3. **Badge logic** is a direct comparison of `note.access_contacts` to
   `thread.contacts`, with no time-of-thread-edit inference.

Enforcement: the send path (and the per-connector ingest path) writes
`access_contacts` for every message-mode note. Thread-mode and
channel-mode notes continue to default to `NULL`.

### Thread/channel-mode: unchanged

`thread.contacts` and `thread.groups` remain the sole source of
visibility. `note.access_contacts` stays `NULL` by default. The new
field on `LinkTypeConfig` is the only change.

## UI: thread header

### Thread-mode (today's behavior)

`AvatarGroup` of `thread.contacts`. No change.

### Channel-mode

The participant strip renders the **channel title** in place of the
AvatarGroup. Same line position and alignment; muted text color
matching current secondary-text styling. No icon, no count, no tap
behavior.

Data path: `thread.id → link.channel_id + link.twist_instance_id →
channel.title`.

**Fallback**: if `channel.title` can't be resolved (channel deleted,
unsynced), render the `AvatarGroup` of `thread.contacts`. Better to
show something than blank.

**Note-badge interaction**: channel-mode ignores `note.access_contacts`
for badge purposes. Slack-style threaded replies are visible to
everyone with channel access; there's no divergence to surface.

### Message-mode

`AvatarGroup` shown, but computed **per-viewer** (see "Dropped Plot
users"). For an active participant this equals
`UNION(note.access_contacts)` across visible notes, which equals
`thread.contacts` — same result as today, different derivation.

## UI: per-note divergence badges (message-mode only)

A badge sits in the gutter above a note body when the note's effective
audience differs from the thread superset, or when it includes a
contact not in the current `thread.contacts`. Hidden otherwise — the
common case has no badge.

Treatment: small pill, subtle background tint + secondary text color.
Catches the eye slightly more than body text, quieter than a warning.
The badge attaches to the note body (not the author header row) so
it's clear what it scopes.

### Badge text rules

From the viewer's perspective. "You" = the viewing user; a contact is
"you" if it's in `user.user_contact_ids()`.

Define:

- `audience` = the note's effective audience (`access_contacts ∪
  {author}`)
- `subset_others` = `audience ∩ thread.contacts \ user.user_contact_ids()`
- `plus_others` = `audience \ thread.contacts \ user.user_contact_ids()`
- `is_subset` = `audience ⊊ thread.contacts ∪ {viewer-contacts}`
- `is_plus`   = `plus_others ≠ ∅`

| Situation | Badge |
|---|---|
| `audience = {viewer}` (author is you, no others) | **Private** |
| `is_subset`, 1 other | **Just [Name] and you** |
| `is_subset`, 2 others | **Just [Name], [Name], and you** |
| `is_subset`, 3+ others | **Just [Name], [Name] +N, and you** |
| `is_plus`, no subset | **Plus [Name]** (or `[Name], [Name] +N` for multiple) |
| `is_subset` and `is_plus` | **Just [Name] and you, plus [Name]** |
| Audience excludes viewer | n/a — viewer can't see the note |

The badge always lists *other* people. "and you" is the consistent
suffix when the viewer is in the audience.

`access_contacts` edits re-render the badge from current data; no
history of past visibility is shown.

## Sharing modal extension (message-mode)

The role-aware modal from the in-flight plan
(`rethink-the-modal-used-abundant-wand.md`) is reused as-is. Message-
mode adds three behaviors on top, all scoped to message-mode threads:

1. **"Dropped" section** below the Shared list. Renders contacts in the
   thread's historical participant set who aren't in `thread.contacts`.
   Tap a row to re-add at default role. Hidden entirely for thread-
   and channel-mode threads.

2. **Remove behavior changes to "drop"**. Removing a contact from the
   Shared list in message-mode moves them to Dropped instead of
   forgetting them entirely. The `contactMeta` entry is still cleared
   (as in the role-aware plan), so a re-add lands at the connector's
   default role.

3. **BCC auto-drop after send**. The send path inspects each
   recipient's role. Any recipient at a `hidden: true` role (Bcc and
   similar) is removed from `thread.contacts` after the message
   leaves. They land in Dropped, where they can be manually re-added.

The semantic shift the user experiences: editing the modal in message-
mode changes who's on the **next message**, not who was historically
on the thread. The Dropped section makes that history visible without
mutating it.

## Heuristic: detecting non-Plot recipient changes

Plot can't read the minds of non-Plot senders. When a new inbound
message arrives in a message-mode thread, we have to decide whether
its To/Cc set represents a deliberate edit to the thread default or a
one-off subset reply.

**Rule**: compare the incoming recipient set to the previous message's
recipient set.

- **Added recipients** are *always* added to `thread.contacts`.
- **Removed recipients** are dropped from `thread.contacts` only if
  **≤ 50% of the previous recipients were removed**. If more than 50%
  were removed, treat it as a private subset reply and leave
  `thread.contacts` unchanged. The note still records its actual
  recipient set in `access_contacts`, and the badge logic surfaces it.

This handles:

- **Bcc introduction** ("introducing Alice and Bob, Bcc'ing the
  connector") — 1 of 3 removed = 33% = real removal.
- **Solicit-input pattern** in a 10-person thread — reply to 2 of 10 =
  80% removed = treated as subset reply.

Edge: a 2-person thread where 1 recipient is removed = 50% = real
removal. Correct: a 1-on-1 becoming none means the other party left.

The threshold may need tuning with real data; ship 50% and revisit if
we see false positives.

## Dropped Plot users

When a Plot user is dropped from a message-mode thread, two things must
happen for privacy:

### Suppression (already supported)

- New notes set `access_contacts` to exclude the dropped user; sync
  filters do the rest.
- Do not bump `thread_unread` / activity indicators for the dropped
  user on notes they can't see.
- From the dropped user's perspective the thread is dormant — no
  badge, no push, no list reordering.

### Anti-leak on the participant list

Today the header AvatarGroup reads `thread.contacts` directly. If
someone is added to the thread after the user is dropped, the dropped
user would see the new avatar appear — leaking that the thread
continued.

**Fix**: for message-mode threads, derive the AvatarGroup as the
**union of `access_contacts` across notes the viewer can see, plus
each visible note's author.**

Combined with the always-explicit `access_contacts` invariant:

- Active participants see everyone, because they see all notes —
  matches `thread.contacts`.
- A dropped user sees only contacts who appeared on notes before the
  drop. Alice (added later) is invisible because she's only on notes
  past the drop point.
- No snapshot table, no extra schema, just a different query for
  message-mode threads.

Channel-mode and thread-mode threads continue to read
`thread.contacts` directly; no derivation cost.

**Intentional carve-out**: if someone privately replies to *just the
dropped user* later, that note legitimately re-includes them. The
"thread re-engaged" signal that produces is correct — it's a private
outreach.

## Implementation order

1. **Twister**: add `sharingModel` to `LinkTypeConfig`. Set the value
   on every existing connector's link type configs (Slack, Linear,
   Gmail, Calendar, etc.). Changeset required.
2. **API**: enforce the always-explicit `access_contacts` invariant on
   the message-mode send and ingest paths. Add the 50%-removal
   heuristic on inbound message ingest.
3. **Flutter — header**: resolve the model from the primary link's
   `LinkTypeConfig`. Render channel title for channel-mode (with
   AvatarGroup fallback). Add per-viewer AvatarGroup derivation for
   message-mode.
4. **Flutter — note badges**: add the badge widget and the audience-
   diff logic. Hide for thread-/channel-mode.
5. **Flutter — sharing modal**: add the Dropped section, the drop-
   instead-of-remove behavior, and the BCC auto-drop on send. All
   gated on message-mode.

Steps 1–2 are server/contract work. Steps 3–5 are client work and can
proceed in parallel once step 1 ships.

## Open follow-ups (later)

- **One-off subset replies** that don't change the thread default.
  Today, every message-mode reply mutates `thread.contacts` per the
  heuristic. A future "send this one to a subset only" affordance
  would skip that mutation.
- **Role display in compose chips** and the thread-header
  participant list (called out as out-of-scope in the role-aware
  modal plan; same here).
- **Channel detail surface** (tap channel title → member list,
  settings). Not on the roadmap yet.
- **Heuristic tuning** — the 50% threshold is a starting point. Watch
  for false positives in production.
