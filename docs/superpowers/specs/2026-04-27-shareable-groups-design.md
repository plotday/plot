# Shareable Groups Design

## Problem

The Plot Team group is set as a default-shared group on every user's "Using Plot" priority via `priority.default_groups`. The intent: when a regular user opens the new-thread page in Using Plot, the Plot Team chip is pre-selected so submitting a thread routes feedback to the Plot team.

It works for Plot team members and breaks silently for everyone else. Two gates fire:

1. **`user.group` view** (`libs/db/schema/90-user-schema/35-group.sql`) only returns `team`/`private` groups to actual team members or group members. Non-members get a null when the Flutter client calls `Group.getOne(id)`, so `_refreshPinnedChips` skips the group entirely — no chip renders.
2. **`share_thread`** (`libs/db/schema/60-functions/share_thread.sql`) blocks non-members from adding `team`/`private` groups to a thread, so even if the chip rendered, submission would be rejected.

The Plot Team group is `type='team'` in production (auto-maintained for the "Plot" team) and `type='private'` in local dev (the Plot Publisher fallback). Both fail both gates.

## Goal

Let any user address the Plot Team group as a recipient on a thread, while preserving existing membership semantics: only Plot team members see threads sent to it.

## Non-goals

- Per-user "share my Family group with you" sharing. The user_group join was discussed and rejected for now (YAGNI). Add when a real per-user-share use case appears.
- Changing `announce` group semantics. Announce stays admin-post / everyone-receive.
- Changing how thread visibility flows from `thread.groups` to readers. The `user_group_ids(user)` function (which drives `user.thread` visibility) keeps returning only groups the user is a member of via `group_member`.

## Design

### Schema

Add a generic stable identifier to `group`:

```sql
ALTER TABLE "public"."group" ADD COLUMN "key" text;
ALTER TABLE "public"."group" ADD CONSTRAINT group_key_unique UNIQUE (key);
```

Mirrors `priority.key` (`'@plot.app'`, `'@plot.twist-dev'`). Nullable; only system-managed groups need one. The Plot Team group gets `key = '@plot.team'`.

No new tables. `user_group` is deferred until a per-user sharing requirement materializes.

### `user.group` view

Add one branch to the visibility WHERE clause:

```sql
WHERE g.archived_at IS NULL
  AND (
      g.type IN ('public', 'announce')
      OR g.key = '@plot.team'                            -- NEW
      OR (g.type = 'team' AND EXISTS (...team_user...))
      OR (g.type = 'private' AND (...admin or member...))
  )
```

`is_member` and `member_contact_ids` logic are unchanged. Non-members of `@plot.team` see the group with `is_member = false` and an empty `member_contact_ids` (the existing CASE's ELSE branch already covers this).

If we ever want a generic "broadcast" abstraction, the `g.key = '@plot.team'` clause grows into `g.key = ANY(...)` or migrates to a flag. Deferred.

### `share_thread` permission

Replace the type-based admin/member gate with a visibility-based gate plus the announce carve-out:

```sql
FOR v_group IN ... LOOP
    IF v_group.type = 'announce' THEN
        IF NOT EXISTS (
            SELECT 1 FROM group_admin
            WHERE group_id = v_group.id AND user_id = p_user_id
        ) THEN
            RAISE EXCEPTION 'Only admins can add announce groups to threads';
        END IF;
    ELSE
        IF NOT EXISTS (
            SELECT 1 FROM "user"."group" ug
            WHERE ug.user_id = p_user_id AND ug.id = v_group.id
        ) THEN
            RAISE EXCEPTION 'User cannot see this group';
        END IF;
    END IF;
END LOOP;
```

Net effect:

- Anyone with picker visibility can add the group to a thread (one rule, one gate).
- Announce stays admin-only post.
- Membership and admin still grant member-level access (seeing existing threads sent to the group). Unchanged.

### Group seeding

**Trigger update** in `libs/db/schema/95-triggers/24-group_auto_maintain.sql`:

- `auto_create_team_group`: when `NEW.name = 'Plot'`, set `key = '@plot.team'` on the inserted group.
- `auto_maintain_team_group_members`'s create-on-demand fallback: same.

**Backfill** in the new migration:

```sql
UPDATE "public"."group"
SET key = '@plot.team'
WHERE auto_maintained = TRUE
  AND auto_team_admin_team_id IS NULL
  AND team_id = (SELECT id FROM team WHERE name = 'Plot' LIMIT 1);
```

**Local-dev caveat:** there's no Plot team locally, so the Plot Publisher group (the fallback used when `activate_invited_user` ran without a Plot team) does not get keyed. Non-Plot-devs in dev still won't see it. Acceptable — dev-environment-only.

### Flutter app

No code changes required. The existing flow works once the group is visible:

- Sync pulls down the group via `user.group` once it's visible.
- `Group.getOne(plotTeamId)` returns non-null.
- `_refreshPinnedChips` (`apps/plot/lib/page/new_thread.dart:320-373`) builds the chip.
- `_buildGroupChip` renders it pre-selected because `priority.default_groups` already contains the Plot Team ID (seeded by `Thread()` constructor reading `priority.inheritedDefaultSharedGroups` at `apps/plot/lib/store/thread.dart:2137-2139`).
- Submission via `share_thread` is now permitted for any user with visibility.

## Data flow (after fix)

1. User opens Using Plot priority. `PriorityBloc.setPriority` constructs a draft `Thread`, which seeds `draft.groups = [plotTeamGroupId]` from `priority.inheritedDefaultSharedGroups`.
2. `_refreshPinnedChips` calls `Group.getOne(plotTeamGroupId)`. Now returns the group (visible via the new `key = '@plot.team'` branch in `user.group`).
3. Pre-selected Plot Team chip renders.
4. User submits thread. `share_thread` is invoked. Visibility check passes (the user has `user.group` visibility). Group is added to `thread.groups`.
5. `file_thread_priority_for_group_members` trigger fires for each Plot Team member, creating `thread_priority` rows so they receive the thread.
6. Author sees the thread because their `thread_priority` row was auto-created and `thread.contacts` includes their linked contact.
7. Random non-Plot-Team users do not see the thread — their `user_group_ids` doesn't include Plot Team and their contact isn't in `thread.contacts`.

## Visibility/permission matrix

| Actor | Sees `@plot.team` in picker? | Can add to thread? | Sees existing threads sent to it? |
|---|---|---|---|
| Plot Team member | yes (member branch) | yes | yes |
| Plot Team admin | yes (admin branch) | yes | yes |
| Regular user | yes (`@plot.team` key branch) | yes | no |
| Archived/inactive user | yes if `user.group` returns row | yes if visibility passes | no |

## Migration

One migration generated from schema changes:

1. `ALTER TABLE "group" ADD COLUMN key text` + UNIQUE constraint.
2. Updated `auto_create_team_group` and `auto_maintain_team_group_members` functions (CREATE OR REPLACE).
3. Updated `user.group` view (CREATE OR REPLACE).
4. Updated `share_thread` function (CREATE OR REPLACE).
5. Backfill `UPDATE` to set `key = '@plot.team'` on the existing Plot Team group (no-op locally where the group doesn't exist).

No backwards-compat concerns. Old workers reading the `group` table ignore the new `key` column. Old workers calling `share_thread` get more-permissive behavior, which is the intended fix.

## Testing

- `flutter analyze` on changed files (none expected unless we add a `key` getter to `Group`).
- Manual: log in as a non-Plot-Team user (locally, this requires creating a "Plot" team to seed `@plot.team`, since the dev fallback uses the unkeyed Plot Publisher group). Open Using Plot's new-thread page. Plot Team chip renders pre-selected. Submit. Verify a Plot Team member receives the thread.
- Verify the author sees their own submitted thread in their Using Plot priority.
- Verify a third non-Plot-Team user does NOT see the thread.
- Verify announce groups still reject non-admin posters.

## Risks & mitigations

- **Visibility leak via key collision:** `key` is UNIQUE, so no collision risk. The view's branch is exact-match on `'@plot.team'`.
- **`share_thread` becomes too permissive:** the visibility-as-permission model is symmetric with how contacts work (you can mention any contact in your address book). Posting to a group never grants the poster read access to existing threads — only members receive what's sent. Risk is bounded.
- **Future "broadcast" groups:** today we hardcode `'@plot.team'`. If a second broadcast group appears, extend the WHERE clause or refactor to a flag. Cheap to evolve.
