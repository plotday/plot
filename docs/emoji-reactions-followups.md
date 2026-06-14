# Emoji reactions — follow-up work

Captured after the initial implementation (branch `emoji-reactions` / commits in
`libs/db/schema/50-tables/{87..89}*.sql`, the per-connector work in
`public/connectors/{slack,ms-teams,google-chat}`, and the Flutter work in
`apps/plot/lib/{store,widget,command}`). Each section below is independently shippable; the order is
"what unblocks what," not strict priority.

## 1. Wire reactions through the existing tag-filter pipeline

**Problem.** Reactions land in `note_reaction` / `thread_reaction` and are invisible to the filter
UI, query layer, and suggestions row that already exist for tags. Today the chips render on
individual notes but nothing else surfaces them for discovery or querying.

**Surfaces that need to learn about reactions:**

| Where                                                                 | What's there today                      | Needs                                                                           |
| --------------------------------------------------------------------- | --------------------------------------- | ------------------------------------------------------------------------------- |
| `widget/unified_header.dart:687` `buildFilters`                       | iterates `allTags.keys`                 | also enumerate priority's reactions                                             |
| `widget/unified_header.dart:740` active-filter chips                  | `ToggleActivityFilter` per `Tag`        | render reaction chips alongside                                                 |
| `state/priority.dart:3104`, `state/thread.dart:229` `tagSuggestions`  | `List<Tag>` from `watchTagsForPriority` | union with reactions present on the priority                                    |
| `store/thread.dart:1416` `watchTagsForPriority`                       | joins `threadTags` Drift table          | parallel `watchReactionsForPriority` reading from `threadReactions`             |
| 18+ `Note.watch` / `Thread.watch*` callsites with `List<Tag>? filter` | only JOINs `note_tag` / `thread_tag`    | accept `List<Reaction>? reactionFilter` and JOIN the reaction tables            |
| `PriorityState.filter` / `ThreadState.filter`                         | `List<Tag>`                             | extend to carry reactions (parallel field or sum type)                          |
| `command/filter.dart` `ToggleActivityFilter` / `SetActivityFilters`   | `Tag`-only                              | parallel `ToggleReactionFilter` or unify into a single sum-typed filter command |

**Shape question to decide.** Either:

- (A) Parallel: `state.filter: List<Tag>` + `state.reactionFilter: List<Reaction>`. Each query gets
  both params. Simpler diff but doubles the surface.
- (B) Sum type: `sealed class FeedFilter { Tag tag } | { Reaction emoji }`. Cleaner long-term but
  every callsite gets touched.

Recommendation: (A) first — it's the additive expand-contract path. Switch to (B) once toggle tags
are gone (§2) and the bipartite story isn't worth the duplication.

**Scope.** ~5–8 commits depending on shape choice.

## 2. Drop toggle tags entirely; migrate to per-user emoji reactions

**Goal.** Tags collapse to just `compute` (system-managed: `todo`, `done`, `archived`, `attachment`,
`link`, `private`, `unread`, `task`, `reading`). Everything currently in the `toggle` range
(100–999) becomes a reaction.

### Semantic change to flag for review

Toggle tags today carry **shared state**: anyone with access flips `Pinned` on and everyone sees it
pinned. Reactions are **per-user**. Migrating means `📌` on a thread now reads as "Kris reacted with
📌", not "this thread is pinned for everyone."

For most toggle tags (`Star`, `Idea`, `Question`, `Decision`, `Warning`) the per-user reading is
arguably more honest — the tag was always a personal annotation anyway, the shared semantics just
made two people's annotations look like one collective statement.

For tags that _did_ carry collective meaning (`Pinned`, `Urgent`, `Blocked`, `Waiting`) the change
is more meaningful. We may want to:

- Replace `Pinned` with a thread-level pinning mechanism (already exists in `priority_setting` for
  priorities; threads could mirror).
- Keep `Urgent`/`Blocked`/`Waiting` per-user — these are arguably also personal context ("I'm
  blocked on this") rather than thread-state.

Decide each case explicitly before flipping; the schema change is mechanical but the product
semantics aren't.

### Toggle tag → emoji mapping (draft)

```text
Pinned    (100) → 📌
Urgent    (101) → 🚨
Goal      (103) → 🎯
Decision  (104) → ⚖️    (or 🤔; see below)
Waiting   (105) → ⏳
Blocked   (106) → 🚧
Warning   (107) → ⚠️
Question  (108) → ❓
Twist     (109) → 🌪️
Star      (110) → ⭐
Idea      (111) → 💡
```

`Decision` collision: today's count-tag mapping uses 🤔 for the `Thinking` count tag
(`Tag.thinking`, id 1013, archived in the backfill migration). Decide between 🤔 and ⚖️ at migration
time.

### Migration

Mirror `20260526195200_backfill_count_tags_to_reactions.sql`:

1. INSERT into `note_reaction` / `thread_reaction` for each toggle-tag row (tag_id ∈ 100–999), with
   the mapped emoji.
2. UPDATE `note_tag` / `thread_tag` set `archived_at = now()` for tag_id 100–999, archived_at IS
   NULL. (Per AGENTS.md, never bare DELETE on synced tables.)

### Dispatch retirement

After the migration:

- `get_tag_type` (`libs/db/schema/40-functions/30-tag.sql`) — drop the toggle branch; only compute
  remains. Becomes:

  ```sql
  IF tag_id BETWEEN 1 AND 99 THEN RETURN 'compute'; END IF;
  RAISE EXCEPTION 'invalid tag_id: %', tag_id;
  ```

- `upsert_thread_tag` / `upsert_note_tag` / `update_thread_tags` / `update_note_tags`
  (`90-user-schema/`) — drop the toggle-tag and count-tag branches entirely; the remaining compute
  branches are much smaller.
- `tag_type` enum value `'toggle'` — eventually drop (one migration later, after the dispatch
  retirement deploys cleanly).

### Flutter

- `apps/plot/lib/store/tag.dart` — remove toggle entries from the `Tag` enum (keep only compute).
  The `Tag.values` consumers should naturally shrink.
- Wherever toggle tags are checked by name (`Tag.pinned`, `Tag.urgent`, etc. — grep all callsites),
  either replace with reaction lookups on `note_reaction` / `thread_reaction`, or — for features
  that need true thread-state semantics (e.g. pinning threads) — add a dedicated column on `thread`.
- Drift schema bump + migration to delete `toggle`-keyed rows in the local cache.

### Order of operations

1. Land §1 (filter pipeline knows about reactions) so the new "pinned-as-reaction" world is
   queryable.
2. Decide per-toggle-tag whether semantic is shared or per-user; move shared ones to dedicated
   columns first.
3. Land the backfill migration.
4. Strip toggle from `Tag` enum and dispatch.

## 3. Phase 6 retirement (count tag dispatch is now dead code)

The backfill migration already archived all `tag_id >= 1000` rows. The dispatch branches that handle
them are unreachable, but the code is still there. Concrete cleanup:

- `libs/db/schema/40-functions/30-tag.sql` — drop the count branch from `get_tag_type`. Once toggle
  tags are also gone (§2), the whole function collapses to a 3-line compute check.
- `libs/db/schema/90-user-schema/{10-update_thread_tags,11-update_note_tags,85-user-sync-upserts}.sql`
  — drop the count-tag specific arms (sibling resolution, only-self guards, todo→done propagation,
  reply-tag bidirectional sync).
- `apps/plot/lib/widget/note.dart` lines 998–1006 still call `topNoteTags` and render the count-tag
  chip row alongside the new reaction row. Once you're confident in the reaction UI, strip the
  count-tag branch — pre-backfill, the chips read from archived rows that just haven't dropped from
  local Drift yet.
- `apps/plot/lib/store/tag.dart` — drop the 28 count-tag enum entries (`Tag.yes` through
  `Tag.dismayed`). Drift schema bump.

## 4. Per-actor `actAs()` write-back (Slack, Teams)

Today both connectors write reactions as the auth user instead of the actual reactor. So when Plot
user A reacts `🎉`, the platform shows the bot or installer reacting — not user A.

**Fix path** (per `public/twister/docs/MULTI_USER_AUTH.md`):

- For each emoji+actor pair in the diff, call
  `integrations.actAs(provider, actorId, threadId, callback)` to obtain the actor's token, then make
  the API call as that user.
- Falls back to the auth user when the actor doesn't have their own auth (matches
  `MULTI_USER_AUTH.md`'s "fallback" pattern).

**Slack.** `onNoteUpdated` in `public/connectors/slack/src/slack.ts` currently iterates
`plotShortcodes` and calls `api.addReaction` as auth. Switch to a per-actor loop with `actAs`.

**Teams.** `onNoteUpdated` is currently a no-op for reactions (the `set*Reaction` / `unset*Reaction`
Graph methods are in place but unwired). Teams enforces one-reaction-per-user-per-message, so this
is the gating reason to wire per-actor write-back rather than a single-user write-back.

## 5. Custom emoji caching (`custom_emoji` table + image proxy)

**Server side.**

- Slack: on connect, fetch `emoji.list` and upsert rows into `custom_emoji` (id format
  `slack:<team_id>/<name>`). On `reaction_added` events, if the reaction name isn't in
  `SLACK_SHORTCODE_TO_UNICODE`, treat as custom and look up / fetch the URL.
- Google Chat: when a reaction carries `customEmoji.uid`, fetch the emoji's metadata and store as
  `google_chat:<workspace>/<uid>`.
- Image proxy route: Slack custom-emoji URLs are token-scoped. Add a Cloudflare Workers route that
  re-signs the upstream URL so clients can fetch without server-issued bearers.

**Client side.**

- Wire `/sync/custom-emoji` into `SyncOrchestrator` — table + sync helpers exist
  (`apps/plot/lib/store/custom_emoji.dart`, `note_reactions.dart`), but nothing schedules the pull.
  Add a `SyncEntity` with `dependsOn: []` and a debounced cadence (custom emoji rarely changes).
- `EmojiText` already does the lookup + Image.network fallback; once rows exist locally, custom
  emoji render automatically.

**Then flip** `reactionCapabilities.customEmoji` from `'none'` to `'workspace'` on Slack and Google
Chat.

## 6. LinkedIn Messaging reactions

The `linkedin-messaging` connector isn't on `origin/main` in this worktree's snapshot but exists
locally. When it lands:

- Inbound extraction (LinkedIn has a fixed 7-reaction set): `['👍','❤️','👏','💡','😂','😮','😢']`.
- Outbound via the messaging API.
- Live updates likely require polling on thread refresh — LinkedIn doesn't expose a reaction
  webhook.
- Declare `reactionCapabilities: { mode: 'fixed', allowed: [...the seven...] }`. The client-side
  capability filter is already wired for this (`reactionCapabilitiesForLinkSource` in
  `apps/plot/lib/store/reaction.dart`).

## 7. Thread-level reaction UI

`thread_reaction` table, sync, RPC, and the `ReactionRow` widget all support thread-level reactions,
but there's no UI entry point. To finish:

- Add a `ToggleThreadReaction` command paralleling `ToggleNoteReaction` in
  `apps/plot/lib/command/note.dart` (or a new `command/thread.dart` if cleaner).
- Add a `_ThreadReactionsRow` widget rendered on the thread header
  (`apps/plot/lib/page/thread.dart`).
- Wire into the thread-level `noteCommands` analogue.

Useful when chat threads accrue reactions on the parent message that should aggregate to the Plot
thread rather than the first note.

## 8. Misc polish

- `apps/plot/lib/widget/widget.dart` — barrel doesn't export `emoji.dart`, `reaction_picker.dart`,
  `reaction_row.dart`. Add them so consumers don't have to deep-import.
- `pubspec.yaml:199` — pre-existing `app.env` asset warning flagged by every `flutter analyze`.
  Unrelated to this work but worth cleaning up.
- Twister changeset (`public/.changeset/emoji-reactions.md`) is staged. When this lands on main,
  follow the publish flow in `public/RELEASING.md`:
  `cd public/twister && pnpm build && npm publish`, then commit the submodule pointer bump.
- Submodule branch — `public/` has its own `emoji-reactions` branch with 4 commits; needs a PR
  upstream.

## 9. Visual verification

The reaction flow has been driven by hand once (`👍` on a Slack-linked note round-tripping back to
Slack as the auth user). End-to-end verification still TBD:

- Plot-native thread: open picker → 🦦 → re-open thread → chip persists with correct count.
- Slack-linked thread with a tunnel running: react in Slack with `:fire:` → Plot shows 🔥 (via
  `SLACK_SHORTCODE_TO_UNICODE`); react in Plot with 🎉 → Slack shows it under the auth user.
- Google Chat-linked thread: confirm bidirectional after the refactor.
- Teams-linked thread: confirm inbound (legacy `like` → `👍` and Unicode `💯` both render).
- LinkedIn-linked thread (post §6): picker only shows the 7 allowed reactions.

The Plot-native case is the one to start with — fewest moving parts and rules out client-side bugs
before adding connector noise.
