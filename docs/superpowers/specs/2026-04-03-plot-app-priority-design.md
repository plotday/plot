# Plot App Priority Design

## Context

Plot currently has four special @plot priorities nested under a per-user `@plot` system priority:
- **Getting Started** (`@plot.getting-started`): Per-user, created by Plot twist's `activate()` with onboarding threads
- **What's New** (`@plot.whats-new`): Global shared, users join as viewer
- **Help & Feedback** (`@plot.help-feedback`): Global root with per-user child priorities
- **Twist Development** (`@plot.twist-dev`): Per-user, under @plot

Problems: fragmented experience, per-user onboarding threads are redundant copies, no support/feedback channel visible to staff, @plot parent priority adds visual clutter.

This redesign replaces all four with a single **"Plot App"** priority, introduces a general readonly visibility model, and removes the @plot parent.

## Architecture

### 1. Readonly Priority Visibility Model

A new general behavior for all priorities containing viewer members:

| Actor | Create threads | Create notes | See private content |
|-------|---------------|-------------|-------------------|
| **Member** (staff) | Public or private | Public or private | All private content in the priority |
| **Viewer** (user) | Auto-private only | Auto-private only | Only own private content |

Members can toggle viewer-created private threads/notes to public.

**DB implementation:** Modify the visibility conditions in `user.thread` and `user.note` views. Currently, private content is visible only to the creator and mentioned users. Add: members (`upe.role = 'member'`) can see all private content in their priorities.

In `user.thread` view (visible union, line 148):
```sql
AND (CASE WHEN a.private = FALSE THEN TRUE
    WHEN a.created_by = upe.user_id THEN TRUE
    WHEN upe.role = 'member' THEN TRUE  -- NEW: members see all private
    ELSE "user".mentioned_in_thread(upe.user_id, a.id)
END)
```

The redacted union (line 182-184) gains the inverse condition — exclude from redaction when user is a member.

Same pattern for `user.note` view — both the visible union and redacted union.

**Safety analysis:** In normal shared priorities, all users are members, so `upe.role = 'member'` is always true and the condition is redundant (no behavior change). The new path only activates when viewers exist alongside members — the readonly priority pattern.

### 2. Plot App Priority (`@plot.app`)

- **Single global priority** shared by all users
- Key: `@plot.app`, title: "Plot App"
- Top-level (not under @plot or any parent)
- Subtitle "Updates, support, and suggestions" hardcoded in Flutter for `@plot.app` key
- Staff are `member` role, users are `viewer` role
- Created by DB function `setup_plot_app_priority(p_user_id)` during activation

### 3. @plot Removal

- The per-user `@plot` system priority is removed
- `@plot.twist-dev` becomes a top-level priority (path under user root, not under @plot)
- All Flutter references to `@plot` as a parent priority are removed
- `Priority.isPlot` logic updated to check `@plot.app` and `@plot.twist-dev` directly

### 4. NewThreadPage: Viewer Mode

When `priority.isViewer` on NewThreadPage:
- **Hide all controls** above NoteEditor: priority selector, Start/Schedule/Private/SubType buttons, type chips (Task/Note/Link/Chat), twist selector
- **Show only** the NoteEditor with placeholder: "Ask for help or share a suggestion"
- Thread is **auto-private** (`private = true` on draft)
- Thread title **auto-generated from content** (no title field shown)

### 5. NoteEditor: Viewer in Public Thread

When a viewer opens a staff's public thread in a readonly priority:
- Simplified NoteEditor: text input only
- Note is auto-private
- No toolbar controls (task toggle, mentions, etc.)

### 6. Activity Feed Default

When `priority.isViewer`:
- Default to `PriorityTab.activityFeed` instead of `PriorityTab.agenda`
- Hide the agenda/activity toggle — always show activity feed
- Disable thread reordering (already done via `isViewer` check)

### 7. Onboarding Threads

Onboarding content becomes pre-existing shared threads in Plot App, created by staff (or seed data). Thread keys for identification:

| Thread | Key |
|--------|-----|
| Welcome to Plot! | `welcome` |
| Create your initial Priorities | `priorities` |
| Add your Connections | `connections` |
| Getting Around | `getting-around` |
| Explore Twists | `twists` |
| Set up Notifications | `notifications` |
| Clean up without losing anything | `clean-up` |

**Activation flow** (`twists/plot/src/index.ts`):
1. Look up `@plot.app` priority
2. For each thread key, look up thread by key in that priority
3. Call `createSchedule()` to add each thread to user's agenda with staggered dates (same schedule as today)

Per-user todo tags are removed (shared threads can't have per-user todos on individual notes).

### 8. Migration

DB migration for existing users:

1. Create global `@plot.app` priority if not exists
2. Create shared onboarding threads with keys
3. For all existing users:
   - Add as viewer to `@plot.app`
   - Set `priority_setting` path override to position under user root
4. Archive `@plot.whats-new` global priority
5. Archive `@plot.help-feedback` global priority and all per-user children
6. Archive per-user `@plot.getting-started` priorities
7. Archive per-user `@plot` priorities
8. Move `@plot.twist-dev` priorities to top-level (reparent under user root instead of @plot)

## Files to Modify

### Database
- `libs/db/schema/90-user-schema/30-thread.sql` — visibility model
- `libs/db/schema/90-user-schema/31-note.sql` — visibility model
- `libs/db/schema/60-functions/setup_plot_app.sql` — new (replaces setup_whats_new + help_feedback)
- Remove `libs/db/schema/60-functions/setup_whats_new.sql`
- Remove `libs/db/schema/60-functions/help_feedback.sql`

### API
- `workers/api/src/app/account.ts` — call setup_plot_app instead of old functions
- `workers/api/src/twist/priority-management.ts` — Twist Dev to top-level

### Plot Twist
- `twists/plot/src/index.ts` — replace activate() body

### Flutter App
- `apps/plot/lib/page/new_thread.dart` — viewer mode
- `apps/plot/lib/page/priority.dart` — activity feed default for viewers
- `apps/plot/lib/widget/note_editor.dart` — viewer simplified mode
- `apps/plot/lib/store/priority.dart` — isPlot/isPlotApp updates
- `apps/plot/lib/widget/priorities_list.dart` — @plot → @plot.app display
- `apps/plot/lib/widget/priorities_shell.dart` — unread badge for Plot App
- `apps/plot/lib/page/priorities.dart` — @plot references
- `apps/plot/lib/command/priority.dart` — isPlot checks

## Verification

1. **New user**: Sign up → Plot App appears with onboarding threads in activity feed, threads on agenda
2. **Viewer UX**: Simplified NewThreadPage, auto-private threads/notes, activity feed only
3. **Staff UX**: See all viewer content, create public threads, toggle private→public
4. **Migration**: Old priorities archived, Plot App created, Twist Dev top-level
5. **Unread**: Plot App unread dot in nav
6. **Lint**: `flutter analyze` + `pnpm lint` pass
7. **DB**: `pnpm diff-schema-migrations` clean
