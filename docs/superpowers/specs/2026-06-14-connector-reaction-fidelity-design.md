# Connector Reaction Fidelity — Design

- **Date:** 2026-06-14
- **Status:** Approved (design); implementation pending
- **Scope:** Chat connectors only (Google Chat, LinkedIn, Instagram, WhatsApp)
- **Branch:** `feat/connector-reactions` (renamed from `feat/ms-teams-reactions`)

## Goal

Every chat platform that supports emoji reactions syncs them **both ways**,
attributed to the **actual reactor**. Inbound (external → Plot) already works
on every connector in scope. This work closes the **outbound** (Plot →
external) gaps by migrating the four remaining connectors from the legacy
connected-user `onNoteUpdated` reconcile to the per-actor
`onNoteReactionChanged` hook — the pattern Slack and MS Teams already use.

## Non-goals (explicitly out of scope)

- **Issue-tracker reactions** (GitHub/Linear/Jira comment & issue reactions).
  Those have no reaction model wired in either direction; adding them is a
  separate, larger project.
- **Google Chat custom (workspace) emoji.** Custom emoji are deliberately
  skipped on **both** inbound sync and outbound write-back today, gated on a
  separate custom-emoji image-caching effort (`google-chat-api.ts`: "skip
  custom emojis until image caching lands"). Keeping outbound Unicode-only
  preserves inbound/outbound symmetry. Revisit when image caching lands.
- Any change to the inbound reaction path or the `reactionCapabilities` SDK
  type (both already in place).

## Background

### Plot's reaction model

`note.reactions` is `{ emoji: ActorId[] }` — **multi-emoji × multi-reactor** —
persisted in `note_reaction`. Emoji are Unicode graphemes or custom-emoji refs
of the form `provider:workspace/name`.

### Two outbound write-back mechanisms

1. **`onNoteReactionChanged(note, thread, actor, emoji, added)` — the correct
   path.** Fires once per `(note, actor, emoji)` transition. The runtime routes
   each event to the **reacting user's own connector instance** via the
   `twist_instance_note_reaction_change` view (keyed on `twist_instance_for_actor`
   / `note_reaction.actor_id`), so the external call runs under *that user's*
   token and is attributed correctly — no `actAs` step.
2. **`onNoteUpdated(note, thread)` — the legacy fallback.** Carries the note's
   full current `reactions` map and runs under the **connector owner's** (single
   connected user's) token. A connector diffs Plot vs. external and applies
   add/remove — but every change is attributed to that one account.

### Dispatch payload constraints (verified)

The reaction dispatch (`workers/api/src/twist/tools/integrations.ts`) builds:

- `note: { id, key, content }` — **no `reactions` map**
- `actor: { id, type: Contact, name: null }`
- args: `[note, thread, actor, emoji, added]` where `added = (archived_at == null)`

So `onNoteReactionChanged` implementations act on the single `(emoji, added)`
signal plus their own per-user state — they **cannot** recompute a desired set
from `note.reactions` (it is not populated).

### `reactionCapabilities`

Already declared on all in-scope connectors (SDK type in
`public/twister/src/connector.ts`): `open-unicode` (Google Chat, Instagram,
WhatsApp) or `fixed` with `allowed` (LinkedIn's 7-emoji set). No changes needed.

### Inbound is already complete

- **Google Chat:** Workspace Events `reaction.v1.created/deleted` re-sync the
  parent message; `listReactions` populates per-user reactors.
- **LinkedIn / Instagram / WhatsApp:** `buildReactionsFromMessage` /
  `buildNoteFromMessage` in `libs/unipile/src/connector-helpers.ts` map
  `ChatMessage.reactions` onto `note.reactions` on every sync-in.

## Current state

| Connector | Inbound | Outbound (current) | Action |
|---|---|---|---|
| Slack | ✅ | ✅ `onNoteReactionChanged`, per-actor + custom emoji | none (reference) |
| MS Teams | ✅ | ✅ `onNoteReactionChanged` (`de1a09c`, on branch) | none |
| Google Chat | ✅ | ⚠️ `onNoteUpdated` — connected-user only; skips `:` | migrate → per-actor |
| LinkedIn | ✅ | ⚠️ `onNoteUpdated`+`pickDesiredReaction` — 1 emoji as connected user | migrate → per-actor |
| Instagram | ✅ | ⚠️ same | migrate → per-actor |
| WhatsApp | ✅ | ⚠️ same | migrate → per-actor |

## Design

### Google Chat (`public/connectors/google-chat/src/google-chat.ts`)

Multi-reaction platform — the `(emoji, added)` signal maps directly to the API.

Add `onNoteReactionChanged(note, thread, _actor, emoji, added)`:

1. Guard: `note.key` must start with `message-`; derive `messageId`; build
   `messageName = \`${meta.spaceName}/messages/${messageId}\``. Bail if missing.
2. **Skip custom emoji**: if `emoji.includes(":")`, return (symmetric with
   inbound; see non-goals).
3. `api = getApi(meta.channelId ?? DM_CHANNEL_ID)` — token is the reactor's
   (per-actor dispatch).
4. `added === true` → `api.createReaction(messageName, emoji)`.
5. `added === false` → `api.listReactions(messageName)`, find this user's
   reaction whose `emoji.unicode === emoji` and `user.name ===` the reactor's
   Google user id (`this.get("auth_google_user")`, which is per-instance =
   per-user), then `api.deleteReaction(reaction.name)`.
6. Wrap external calls in try/catch + `console.warn` (best-effort, consistent
   with existing connector style).

Remove the reaction-reconcile block from `onNoteUpdated` (keep content-edit
sync only) and update its comment to: reactions handled separately via
`onNoteReactionChanged` so each emoji is attributed to its reactor (matching
Slack/Teams).

### LinkedIn / Instagram / WhatsApp (`connectors/{name}/src/{name}.ts`)

**One-reaction-per-user** platforms via Unipile:
`UnipileMessaging.setMessageReaction({channelId, messageId, reaction})` replaces
the user's reaction; `clearMessageReaction({channelId, messageId})` removes it
(no emoji arg). Because each user can hold only one reaction, the connector
tracks the emoji it last pushed **for this user** in connector state
(`reaction_sent:${messageId}` — already per-user since dispatch runs on the
user's own instance).

Add `onNoteReactionChanged(note, thread, _actor, emoji, added)`:

1. Guard: `meta.channelId` present; `note.key` starts with `message-`; derive
   `messageId`. Bail otherwise.
2. **LinkedIn only:** if `emoji` ∉ `LINKEDIN_REACTIONS`, return (platform can't
   represent it; the picker already filters, this is defensive).
3. `added === true`:
   - `setMessageReaction({channelId, messageId, reaction: emoji})`
   - `set("reaction_sent:${messageId}", emoji)`
4. `added === false`:
   - read `last = get("reaction_sent:${messageId}")`
   - if `last === emoji` → `clearMessageReaction({channelId, messageId})` +
     `clear("reaction_sent:${messageId}")`
   - else no-op (the user's current platform reaction is a different, still-active
     emoji, or we never pushed this one).
5. try/catch + `console.warn` (best-effort).

**Remove the `onNoteUpdated` override entirely** on all three — it did *only*
reaction reconcile (these platforms don't support message-content edits), so
deleting it reverts to the base-class no-op. Drop the now-unused
`pickDesiredReaction` import. (`pickDesiredReaction` stays in
`libs/unipile/connector-helpers.ts` — still covered by its own unit tests.)

## Behavior changes to communicate

- A reaction added by a Plot user who has **no connection of that type** is no
  longer pushed to the external service. Previously the connected user's single
  reaction was pushed for *any* reactor (collapsing/mis-attributing). New
  behavior is correct per-actor semantics — you cannot react as someone else —
  and removes the prior mis-attribution. Note in the PR description.
- On one-per-user platforms, a single user stacking multiple emoji in Plot
  (e.g. 👍 then ❤️) results in **last-write-wins** on the external side; Plot
  retains all. This is an inherent platform limit, not a regression. Document it
  in code comments.

## Edge cases

- `note.key` missing/malformed → no-op (guard).
- Required `meta` (`spaceName` / `channelId`) missing → `console.warn` + no-op.
- Google Chat removal when the reaction is already gone externally →
  `listReactions` yields no match → no `deleteReaction` call (harmless).
- One-per-user cross-emoji removal handled by the `last === emoji` state guard.
- Custom emoji (`provider:...` ref) on Google Chat → skipped (non-goal).

## Testing

- `pnpm exec tsc --noEmit` clean in each of the four connector packages.
- `pnpm build` clean (twister + connectors); `plot lint` for google-chat,
  `tsc --noEmit` for the private connectors.
- Unit tests: mirror Slack's `onNoteReactionChanged` tests for each connector
  where a `*.test.ts` harness exists — assert: add → set/create call; remove of
  the active emoji → clear/delete call; remove of a non-active emoji on
  one-per-user → no call; LinkedIn disallowed emoji → no call; custom emoji on
  Google Chat → no call. Keep `connector-helpers.test.ts` green.
- **Manual E2E** (real multi-account, deferred follow-up): two users react in
  Plot; confirm each reaction appears on the external platform under the right
  account, and removal clears only that user's reaction.

## Workspace, branches, PRs

- **Worktree:** `.claude/worktrees/feat/connector-reactions` (isolated; no DB
  needed). Core branch on `origin/main`; submodule `public/` on
  `feat/connector-reactions` @ `de1a09c`.
- **Public (submodule):** rename `feat/ms-teams-reactions` →
  `feat/connector-reactions`; add the Google Chat commit. Extends public
  PR #200 (retitle to all-connector reactions; GitHub preserves the PR across a
  branch rename). No changeset (connector-only change; changesets are for
  `twister/` only).
- **Core (this repo):** the three private-connector edits + spec doc on
  `feat/connector-reactions` → separate core PR. Bump the `public` submodule
  pointer after the public side merges.
- `docs/updates.md` entry (user-facing): reactions you add in chat connectors
  now sync to the other side as you. `docs/features.md` only if it claims
  reaction support per connector.

## Implementation order

1. Google Chat (public submodule) — commit on `feat/connector-reactions`.
2. LinkedIn, Instagram, WhatsApp (core) — one commit (or one per connector).
3. Tests + lint/build verification per package.
4. `docs/updates.md`; finalize; submodule pointer bump after public merge.
