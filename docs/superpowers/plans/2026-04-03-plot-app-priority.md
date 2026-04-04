# Plot App Priority Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the four @plot sub-priorities (Getting Started, What's New, Help & Feedback, Twist Development) with a single "Plot App" priority and a general readonly visibility model, then remove @plot.

**Architecture:** New DB views grant members full visibility of private content. A single global "Plot App" priority replaces three separate ones. The Flutter app special-cases viewer priorities with simplified thread/note creation. Twist Development moves to top-level.

**Tech Stack:** PostgreSQL (schema views, functions, migrations), TypeScript (Cloudflare Workers API), Dart/Flutter (app), Twister SDK

---

### Task 1: Update DB visibility — `user.thread` view

**Files:**
- Modify: `libs/db/schema/90-user-schema/30-thread.sql:146-184`

- [ ] **Step 1: Add member visibility to the visible union**

In the WHERE clause of the first SELECT (visible threads), change lines 148-151:

```sql
    AND (CASE WHEN a.private = FALSE THEN TRUE
        WHEN a.created_by = upe.user_id THEN TRUE
        WHEN upe.role = 'member' THEN TRUE
        ELSE "user".mentioned_in_thread(upe.user_id, a.id)
    END)
```

The new `WHEN upe.role = 'member' THEN TRUE` line means members of a priority can see all private threads in it.

- [ ] **Step 2: Update the redacted union to exclude members**

In the WHERE clause of the second SELECT (redacted rows), change lines 180-184:

```sql
WHERE
    (a.draft = FALSE OR a.created_by = upe.user_id)
    AND a.private = TRUE
    AND a.created_by != upe.user_id
    AND upe.role != 'member'
    AND NOT "user".mentioned_in_thread(upe.user_id, a.id);
```

The new `AND upe.role != 'member'` line excludes members from seeing redacted rows — they see the real content via the visible union instead.

- [ ] **Step 3: Commit**

```bash
git add libs/db/schema/90-user-schema/30-thread.sql
git commit -m "feat: members see all private threads in their priorities"
```

---

### Task 2: Update DB visibility — `user.note` view

**Files:**
- Modify: `libs/db/schema/90-user-schema/31-note.sql:1-79`

- [ ] **Step 1: Add member visibility to note-level conditions in visible union**

Change lines 30-32 (note-level privacy):

```sql
    AND (n.private = FALSE
        OR n.created_by = upe.user_id
        OR upe.user_id = ANY(n.mentions)
        OR upe.role = 'member')
```

- [ ] **Step 2: Add member visibility to thread-level conditions in visible union**

Change lines 35-38 (thread-level privacy):

```sql
    AND (CASE WHEN a.private = FALSE THEN TRUE
        WHEN a.created_by = upe.user_id THEN TRUE
        WHEN upe.role = 'member' THEN TRUE
        ELSE "user".mentioned_in_thread(upe.user_id, a.id)
    END)
```

- [ ] **Step 3: Update the redacted union WHERE clause**

Change lines 63-77 to exclude members from redaction:

```sql
WHERE
    (n.draft = FALSE OR n.created_by = upe.user_id)
    AND (a.draft = FALSE OR a.created_by = upe.user_id)
    AND upe.role != 'member'
    -- Hidden by note-level OR thread-level privacy
    AND (
        -- Note is private and user can't see it
        (n.private = TRUE
            AND n.created_by != upe.user_id
            AND NOT (upe.user_id = ANY(COALESCE(n.mentions, CAST('{}' AS uuid[])))))
        OR
        -- Thread is private and user can't see it
        (a.private = TRUE
            AND a.created_by != upe.user_id
            AND NOT "user".mentioned_in_thread(upe.user_id, a.id))
    );
```

- [ ] **Step 4: Commit**

```bash
git add libs/db/schema/90-user-schema/31-note.sql
git commit -m "feat: members see all private notes in their priorities"
```

---

### Task 3: Create `setup_plot_app_priority` DB function

**Files:**
- Create: `libs/db/schema/60-functions/setup_plot_app.sql`

- [ ] **Step 1: Write the function**

Create `libs/db/schema/60-functions/setup_plot_app.sql`:

```sql
-- Create/join @plot.app priority for a user as a viewer member
-- The first call creates the global priority; subsequent calls just join the user
-- Positions under user's root priority via priority_settings
CREATE OR REPLACE FUNCTION public.setup_plot_app_priority (p_user_id uuid)
    RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_priority_id uuid;
    v_priority_path ltree;
    v_contact_id uuid;
    v_user_root_path ltree;
    v_override_path ltree;
BEGIN
    -- Get or create @plot.app priority
    SELECT
        id, path INTO v_priority_id, v_priority_path
    FROM
        priority
    WHERE
        key = '@plot.app'
    LIMIT 1;

    IF v_priority_id IS NULL THEN
        v_priority_path := generate_path (NULL);
        INSERT INTO priority (created_by, title, path, color, key, updated_by)
            VALUES (p_user_id, 'Plot App', v_priority_path, 7, '@plot.app', 0)
        RETURNING
            id INTO v_priority_id;
        -- Clean up any auto-created personal entry
        DELETE FROM priority_user
        WHERE user_id = p_user_id
            AND priority_id = v_priority_id
            AND personal = TRUE;
    END IF;

    -- Get user's contact_id
    SELECT
        id INTO v_contact_id
    FROM
        contact
    WHERE
        user_id = p_user_id
        AND "primary" = TRUE
    LIMIT 1;

    -- Add priority_contact (idempotent)
    IF v_contact_id IS NOT NULL THEN
        INSERT INTO priority_contact (priority_id, contact_id)
            VALUES (v_priority_id, v_contact_id)
        ON CONFLICT (priority_id, contact_id)
            DO NOTHING;
    END IF;

    -- Add priority_user with viewer role (idempotent - don't overwrite existing role)
    INSERT INTO priority_user (user_id, priority_id, personal, role)
        VALUES (p_user_id, v_priority_id, FALSE, 'viewer')
    ON CONFLICT (user_id, priority_id)
        DO NOTHING;

    -- Position under user's root via priority_settings
    SELECT
        p.path INTO v_user_root_path
    FROM
        priority_user pu
        JOIN priority p ON pu.priority_id = p.id
    WHERE
        pu.user_id = p_user_id
        AND pu.personal = TRUE
    LIMIT 1;

    IF v_user_root_path IS NOT NULL THEN
        v_override_path := generate_path (v_user_root_path);
        INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (p_user_id, v_priority_id, 'path', to_jsonb(ltree2text(v_override_path)))
        ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
        INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (p_user_id, v_priority_id, 'title', to_jsonb('Plot App'::text))
        ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
    END IF;

    RETURN jsonb_build_object('success', TRUE, 'priority_id', v_priority_id);
END;
$function$;
```

- [ ] **Step 2: Commit**

```bash
git add libs/db/schema/60-functions/setup_plot_app.sql
git commit -m "feat: add setup_plot_app_priority DB function"
```

---

### Task 4: Remove old DB functions and generate migration

**Files:**
- Remove: `libs/db/schema/60-functions/setup_whats_new.sql`
- Remove: `libs/db/schema/60-functions/help_feedback.sql`

- [ ] **Step 1: Delete old functions**

```bash
rm libs/db/schema/60-functions/setup_whats_new.sql
rm libs/db/schema/60-functions/help_feedback.sql
```

- [ ] **Step 2: Generate migration**

```bash
pnpm gen-migration -- plot_app_priority_rearchitecture
```

- [ ] **Step 3: Apply migration to local DB**

```bash
pnpm apply-migrations
```

- [ ] **Step 4: Verify schema sync**

```bash
pnpm diff-schema-migrations
```

Expected: no differences.

- [ ] **Step 5: Regenerate TypeScript types**

```bash
pnpm types
```

- [ ] **Step 6: Commit**

```bash
git add libs/db/schema/ libs/db/migrations/ libs/db/src/types.ts
git commit -m "feat: migration for Plot App priority and readonly visibility"
```

---

### Task 5: Add data migration for existing users

**Files:**
- Modify: the migration file created in Task 4 (append data migration SQL)

- [ ] **Step 1: Add data migration SQL to the generated migration file**

Append to the end of the migration file created in Task 4. This handles existing users:

```sql
-- Data migration: archive old @plot sub-priorities and set up Plot App for existing users

-- 1. Archive @plot.whats-new
UPDATE priority SET archived_at = now() WHERE key = '@plot.whats-new' AND archived_at IS NULL;

-- 2. Archive @plot.help-feedback and all children
UPDATE priority SET archived_at = now()
WHERE (key = '@plot.help-feedback' OR key LIKE '@plot.help-feedback-%')
AND archived_at IS NULL;

-- 3. Archive @plot.getting-started priorities (per-user)
UPDATE priority SET archived_at = now()
WHERE key = '@plot.getting-started' AND archived_at IS NULL;

-- 4. Move @plot.twist-dev to top-level: for each user, reparent their twist-dev
-- priority_setting path override to be under user root instead of under @plot.
-- The actual priority.path stays global; the override is what matters for display.
-- Twist Development priorities that have path overrides under @plot need to be
-- updated to be directly under user root instead.
UPDATE priority_setting ps
SET value = to_jsonb(
    ltree2text(
        generate_path(
            (SELECT p.path FROM priority_user pu
             JOIN priority p ON pu.priority_id = p.id
             WHERE pu.user_id = ps.user_id AND pu.personal = TRUE
             LIMIT 1)
        )
    )
)
FROM priority pr
WHERE ps.priority_id = pr.id
AND pr.key = '@plot.twist-dev'
AND ps.key = 'path';

-- 5. Archive @plot priorities (per-user system priority)
UPDATE priority SET archived_at = now()
WHERE key = '@plot' AND archived_at IS NULL;

-- 6. Set up Plot App for all existing users who don't have it yet
-- (Runs setup_plot_app_priority for each active user)
DO $$
DECLARE
    v_user record;
BEGIN
    FOR v_user IN
        SELECT DISTINCT u.id
        FROM "user" u
        WHERE NOT EXISTS (
            SELECT 1 FROM priority_user pu
            JOIN priority p ON pu.priority_id = p.id
            WHERE pu.user_id = u.id AND p.key = '@plot.app'
        )
    LOOP
        PERFORM setup_plot_app_priority(v_user.id);
    END LOOP;
END $$;
```

- [ ] **Step 2: Apply migration**

```bash
pnpm apply-migrations
```

- [ ] **Step 3: Commit**

```bash
git add libs/db/migrations/
git commit -m "feat: data migration for existing users to Plot App"
```

---

### Task 6: Update API account activation

**Files:**
- Modify: `workers/api/src/app/account.ts:541-671`

- [ ] **Step 1: Replace setup_help_feedback_priority and setup_whats_new_priority calls**

Replace the Help & Feedback setup block (lines ~541-561) and What's New setup block (lines ~658-671) with a single Plot App setup call. Remove both old blocks and add:

```typescript
  // Step 9: Set up Plot App priority
  try {
    await rpc(c.var.db, "setup_plot_app_priority", {
      p_user_id: user.id,
    });
  } catch (error) {
    // Fail open - log but don't block activation
    const context = extractRequestContext(c);
    const logger = createLogger(context);
    logger.error("Failed to setup Plot App priority", error as Error, {
      user_id: user.id,
    });
  }
```

Remove the `if (isNewUser)` block around What's New (lines ~658-671) since Plot App is set up for all new users in the step above.

- [ ] **Step 2: Verify lint passes**

```bash
pnpm --filter @plotday/api lint
```

- [ ] **Step 3: Commit**

```bash
git add workers/api/src/app/account.ts
git commit -m "feat: use setup_plot_app_priority in account activation"
```

---

### Task 7: Move Twist Development to top-level

**Files:**
- Modify: `workers/api/src/twist/priority-management.ts:77-141`

- [ ] **Step 1: Update getOrCreateTwistDevelopmentPriority**

The function currently creates Twist Dev as a child of the Plot priority. Change it to create under the user's root priority instead. Replace lines 81-141:

```typescript
export async function getOrCreateTwistDevelopmentPriority(
  userId: string,
  db: Kysely<DB>
): Promise<string> {
  // Get user's root priority path
  const rootResult = await db
    .selectFrom("priority_user")
    .innerJoin("priority", "priority.id", "priority_user.priority_id")
    .select(["priority.path"])
    .where("priority_user.user_id", "=", userId)
    .where("priority_user.personal", "=", true)
    .executeTakeFirst();

  if (!rootResult) {
    throw new Error("User has no root priority");
  }

  const rootPath = rootResult.path as string;
  const rootPathPart = rootPath.split(".")[0];

  // Try to find existing Twist Development priority by key, scoped to root
  const existingResult = await db
    .selectFrom("priority")
    .select(["id"])
    .where("key", "=", "@plot.twist-dev")
    .where(sql<boolean>`path <@ ${rootPathPart}::ltree`)
    .executeTakeFirst();

  if (existingResult) {
    return existingResult.id;
  }

  // Generate child path under user root
  const path = generatePath(rootPath);

  // Create the Twist Development priority
  try {
    const createResult = await db
      .insertInto("priority")
      .values({
        created_by: userId,
        title: "Twist Development",
        path: path as string,
        updated_by: 0,
        key: "@plot.twist-dev",
      })
      .returning(["id"])
      .executeTakeFirstOrThrow();

    return createResult.id;
  } catch (insertError) {
    const retryResult = await db
      .selectFrom("priority")
      .select(["id"])
      .where("key", "=", "@plot.twist-dev")
      .where(sql<boolean>`path <@ ${rootPathPart}::ltree`)
      .executeTakeFirst();
    if (retryResult) {
      return retryResult.id;
    }
    throw insertError;
  }
}
```

- [ ] **Step 2: Remove the `getOrCreatePlotPriority` import/usage if it was only used here**

Check if `getOrCreatePlotPriority` is used elsewhere. If only used by this function, the import can stay but the call is removed (it may be used elsewhere for other purposes).

- [ ] **Step 3: Verify lint passes**

```bash
pnpm --filter @plotday/api lint
```

- [ ] **Step 4: Commit**

```bash
git add workers/api/src/twist/priority-management.ts
git commit -m "feat: create Twist Development as top-level priority"
```

---

### Task 8: Update Plot twist activate()

**Files:**
- Modify: `twists/plot/src/index.ts:63-363`

- [ ] **Step 1: Replace the activate() method**

Replace the entire `activate()` method body. Instead of creating per-user onboarding threads, look up the shared `@plot.app` priority and add its threads to the user's agenda:

```typescript
  async activate(_priority: Pick<Priority, "id">, context?: { actor: Actor }) {
    // Look up the Plot App priority
    const plotApp = await this.tools.plot.createPriority({
      title: "Plot App",
      key: "@plot.app",
    });

    // If the priority was just created (first user), we don't have onboarding
    // threads yet — they'll be created by the data migration or staff.
    if (plotApp.created) {
      return;
    }

    // Get owner contact for per-user schedules
    const owner = context?.actor ? await this.tools.plot.getOwner() : null;
    if (!owner) return;

    // Get threads in the Plot App priority
    const threads = await this.tools.plot.getThreads({
      priorityId: plotApp.id,
      includeDescendants: false,
      limit: 20,
    });

    // Compute staggered schedule dates
    const today = new Date();
    const dates = [0, 0, 0, 0, 1, 2, 3].map((offset) => {
      const d = new Date(today);
      d.setDate(d.getDate() + offset);
      return d.toISOString().slice(0, 10);
    });

    // Define expected onboarding thread titles and their schedule order
    const onboardingOrder = [
      { title: "Welcome to Plot!", date: dates[0], order: 100 },
      { title: "Create your initial Priorities", date: dates[1], order: 200 },
      { title: "Add your Connections", date: dates[2], order: 300 },
      { title: "Getting Around", date: dates[3], order: 400 },
      { title: "Explore Twists", date: dates[4], order: 100 },
      { title: "Set up Notifications", date: dates[5], order: 100 },
      { title: "Clean up without losing anything", date: dates[6], order: 100 },
    ];

    // Match threads by title and add to agenda
    for (const config of onboardingOrder) {
      const thread = threads.find((t) => t.title === config.title);
      if (thread) {
        try {
          await this.tools.plot.createSchedule({
            threadId: thread.id,
            start: config.date === dates[0] ? "1970-01-01" : config.date,
            userId: owner.id,
            order: config.order,
          });
        } catch {
          // Schedule may already exist — ignore
        }
      }
    }
  }
```

- [ ] **Step 2: Remove unused imports**

Remove `ThemeColor` from imports if no longer used (it was used for `color: ThemeColor.Catalyst` on the old priority creation).

- [ ] **Step 3: Verify lint passes**

```bash
cd twists/plot && pnpm lint
```

- [ ] **Step 4: Commit**

```bash
git add twists/plot/src/index.ts
git commit -m "feat: Plot twist activate() adds shared onboarding threads to agenda"
```

---

### Task 9: Flutter — Update Priority model (isPlot)

**Files:**
- Modify: `apps/plot/lib/store/priority.dart:812-819,1098-1103`

- [ ] **Step 1: Update `excludePlot` to filter `@plot.app` and `@plot.twist-dev`**

Replace the `excludePlot` method (lines 812-819):

```dart
  /// Filters out system priorities (@plot.app, @plot.twist-dev) from the
  /// main priority list. These are shown in their own section.
  static List<Priority> excludePlot(List<Priority> priorities) {
    return priorities
        .where((p) => p.key != '@plot.app' && p.key != '@plot.twist-dev')
        .toList();
  }
```

- [ ] **Step 2: Update `isPlot` getter**

Replace lines 1101-1103:

```dart
  /// Whether this is a system priority that shouldn't be edited/archived by users.
  bool get isPlot =>
      key == '@plot.app' || key == '@plot.twist-dev' || key == '@plot';

  /// Whether this is the Plot App priority.
  bool get isPlotApp => key == '@plot.app';
```

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/store/priority.dart
git commit -m "feat: update Priority.isPlot and excludePlot for new system priorities"
```

---

### Task 10: Flutter — NewThreadPage viewer mode

**Files:**
- Modify: `apps/plot/lib/page/new_thread.dart:950-1104`

- [ ] **Step 1: Set draft to private when viewer**

In `_initializeDraft()` (around line 190), after `_applyDefaultType()`, add:

```dart
    // In viewer priorities, threads are always private
    if (mounted) {
      final priority = context.read<PriorityBloc>().state.draft.priority;
      if (priority.isViewer) {
        final bloc = context.read<PriorityBloc>();
        if (!bloc.state.draft.private) {
          await bloc.updateDraft(bloc.state.draft.copyWith(private: true));
        }
      }
    }
```

- [ ] **Step 2: Add viewer check to build method**

In the `build()` method, add a viewer-mode shortcut before the existing layout. Inside the `BlocConsumer`'s `builder` (after line 972 where `state` is available), add an early return for viewer priorities:

```dart
              // Viewer mode: simplified new thread creation
              if (state.draft.priority.isViewer) {
                return PopScope(
                  canPop: false,
                  onPopInvokedWithResult: (didPop, result) {
                    if (!didPop) {
                      if (ModalProvider.tryDismissTopModal(context)) return;
                      if (!context.isMultiPanel) {
                        context.run(ChangeCurrentThread(null));
                      }
                    }
                  },
                  child: Scaffold(
                    translucent: true,
                    scrollable: false,
                    childPad: false,
                    body: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Spacer(),
                        Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: context.contentPaddingH,
                          ),
                          child: NoteEditor(
                            key: _threadEditorKey,
                            draft: state.draftNote,
                            thread: state.draft,
                            twists: _draftTwists ?? state.twists,
                            actors: state.actors,
                            onDraftChanged: (thread, {note}) async {
                              if (!context.mounted) return;
                              await priorityBloc.updateDraft(
                                thread,
                                note: note,
                              );
                            },
                            flushToBottom: !layoutState.multiPanel,
                            showScheduleActions: false,
                            hint: 'Ask for help or share a suggestion',
                            viewerMode: true,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }
```

This inserts before the existing `return PopScope(...)` at line 974.

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/page/new_thread.dart
git commit -m "feat: simplified NewThreadPage for viewer priorities"
```

---

### Task 11: Flutter — NoteEditor viewer mode

**Files:**
- Modify: `apps/plot/lib/widget/note_editor.dart`

- [ ] **Step 1: Add `viewerMode` parameter to NoteEditor**

Find the NoteEditor constructor and add:

```dart
  final bool viewerMode;
```

With default `this.viewerMode = false` in the constructor.

- [ ] **Step 2: Hide toolbar controls in viewer mode**

In the toolbar section (around line 690), wrap the existing toolbar Row children with a viewer mode check. The Row that contains Start/Schedule/Assignee buttons should be hidden when `widget.viewerMode` is true. Find the Row starting around line 695 and wrap:

```dart
            child: Row(
              children: [
                if (!widget.viewerMode && widget.showScheduleActions &&
                    !thread.priority.isViewer) ...[
```

And similarly for the assignee button at line 729:

```dart
                if (!widget.viewerMode && thread.priority.sharing && !thread.priority.isViewer)
```

- [ ] **Step 3: Auto-set private on viewer notes**

When the NoteEditor is in `viewerMode`, ensure the draft note is marked private. In the submit/save logic, add a check to force `private = true` before saving.

- [ ] **Step 4: Run flutter analyze**

```bash
cd apps/plot && flutter analyze
```

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/widget/note_editor.dart
git commit -m "feat: NoteEditor viewerMode hides toolbar controls"
```

---

### Task 12: Flutter — Activity feed default for viewer priorities

**Files:**
- Modify: `apps/plot/lib/page/priority.dart:690,1088-1106,1831-1890`

- [ ] **Step 1: Default to activity feed when viewer**

In `_PriorityPageState`, update the initial tab logic. At line 690, change:

```dart
  PriorityTab _currentTab = PriorityTab.agenda;
```

This is set statically, but we need context. Instead, override in `didChangeDependencies` — in the section where `_tabNotifier` is synced (line 741-748), add after the existing logic:

```dart
      if (_tabNotifier != null) {
        if (!_appliedInitialTab && widget.initialTab != null) {
          _appliedInitialTab = true;
          _applyInitialTab();
        } else {
          _currentTab = _tabNotifier!.value;
        }
        // Force activity feed for viewer priorities
        final priorityBloc = context.read<PriorityBloc>();
        if (priorityBloc.state.context.isViewer &&
            _currentTab == PriorityTab.agenda) {
          _currentTab = PriorityTab.activityFeed;
          _tabNotifier!.value = PriorityTab.activityFeed;
        }
      }
```

- [ ] **Step 2: Hide desktop tab bar for viewer priorities**

In `_buildDesktopBody` (line 1086), wrap the `_DesktopTabBar` with a viewer check:

```dart
    return Column(
      children: [
        if (!state.context.isViewer)
          BlocSelector<PrioritiesBloc, PrioritiesState, bool>(
            selector: (prioritiesState) {
              final p = prioritiesState.priorities.firstWhereOrNull(
                (p) => p.id == state.context.id,
              );
              if (p == null) return false;
              return prioritiesState.priorities.any(
                (d) => (d.id == p.id || p.path.isParent(d.path)) && d.unread,
              );
            },
            builder: (context, hasUnread) => _DesktopTabBar(
              currentTab: _currentTab,
              onTabChanged: _onDesktopTabChanged,
              hasUnreadActivity: hasUnread,
              priority: state.context,
            ),
          ),
```

- [ ] **Step 3: Force activity feed on mobile for viewer priorities**

In the mobile branch of `build()` (around line 1012), the `isUpNext` check on line 779 determines which list to show. Since we force `_currentTab = PriorityTab.activityFeed` for viewers in didChangeDependencies, `isUpNext` will be false and the activity feed will show. No additional change needed here.

- [ ] **Step 4: Run flutter analyze**

```bash
cd apps/plot && flutter analyze
```

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/page/priority.dart
git commit -m "feat: default to activity feed for viewer priorities"
```

---

### Task 13: Flutter — Update priorities list and shell

**Files:**
- Modify: `apps/plot/lib/widget/priorities_list.dart:515-588`
- Modify: `apps/plot/lib/widget/priorities_shell.dart:306-348`
- Modify: `apps/plot/lib/page/priorities.dart:84-138`

- [ ] **Step 1: Update priorities_list.dart**

Replace the "Fourth group: Plot section" block (lines 569-586). Instead of looking for `@plot` and showing its children, look for `@plot.app` directly and show it:

```dart
              // Fourth group: Plot App
              ...() {
                final plotApp = widget.root.children.firstWhereOrNull(
                  (p) => p.key == '@plot.app',
                );
                return [
                  if (widget.showPlotSection && plotApp != null) ...[
                    SizedBox(height: 16),
                    ListTile(
                      title: 'Plot',
                      style: ListTileStyle.header,
                      textStyle: headerStyle,
                      noHoverHighlight: true,
                      centered: true,
                    ),
                    ...buildReorderablePriorityItems(
                      context,
                      [plotApp],
                      textStyle: itemStyle,
                    ),
                  ],
                ];
              }(),
```

Also update the `allPriorities` filter (line 522-524) to exclude `@plot.app`:

```dart
                final allPriorities = widget.root.children
                    .where((p) => p.key != '@plot' && p.key != '@plot.app')
                    .toList();
```

Remove the `plotPriority` variable (line 518-520) since it's no longer needed — but check if it's used elsewhere in the method. If `plotPriority` was only used for the "Plot section" rendering, remove it entirely.

- [ ] **Step 2: Update priorities_shell.dart**

Replace the unread badge logic (lines 308-318) to check `@plot.app` instead of `@plot` children:

```dart
                                  final plotApp = state.root?.children
                                      .firstWhereOrNull(
                                        (p) => p.key == '@plot.app',
                                      );
                                  final hasUnread = plotApp?.unread ?? false;
```

Remove the `whatsNew` and `helpFeedback` lookups.

- [ ] **Step 3: Update priorities.dart**

Replace the desktop sidebar unread logic (lines 84-138). Change:

```dart
                      final plotApp = root.children
                          .firstWhereOrNull((p) => p.key == '@plot.app');
```

And update the `hasUnread` check (line 136-138):

```dart
                                      final hasUnread =
                                          plotApp?.unread ?? false;
```

Remove the `plotPriority`, `whatsNew`, `helpFeedback` lookups.

- [ ] **Step 4: Run flutter analyze**

```bash
cd apps/plot && flutter analyze
```

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/widget/priorities_list.dart apps/plot/lib/widget/priorities_shell.dart apps/plot/lib/page/priorities.dart
git commit -m "feat: update priorities list and shell for Plot App"
```

---

### Task 14: Flutter — Update settings commands

**Files:**
- Modify: `apps/plot/lib/command/settings.dart:69-90`

- [ ] **Step 1: Replace @plot children lookup with @plot.app**

Replace lines 69-90 with:

```dart
  Command? plotAppCmd;
  if (prioritiesState != null) {
    final plotApp = prioritiesState.priorities.firstWhereOrNull(
      (p) => p.key == '@plot.app',
    );
    if (plotApp != null) {
      final isArchived = plotApp.archivedAt != null;
      if (!isArchived || showAllPriorities) {
        plotAppCmd = OpenPriority(plotApp);
      }
    }
  }
```

Then update the `settingsCommands()` call to pass `plotAppCmd` instead of the three separate commands (`gettingStartedCmd`, `helpFeedbackCmd`, `whatsNewCmd`).

Check what `settingsCommands()` expects and update its signature accordingly.

- [ ] **Step 2: Run flutter analyze**

```bash
cd apps/plot && flutter analyze
```

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/command/settings.dart
git commit -m "feat: update settings commands for Plot App"
```

---

### Task 15: Flutter — Add hardcoded subtitle for Plot App

**Files:**
- Modify: `apps/plot/lib/widget/priorities_list.dart` (where priority items are rendered)

- [ ] **Step 1: Add subtitle display for @plot.app**

Find where priority items are rendered in the priority list (the `buildReorderablePriorityItems` function or the `PriorityLabel` widget). Add a subtitle display when `priority.key == '@plot.app'`:

```dart
// In the list tile for @plot.app, add:
subtitle: priority.key == '@plot.app' ? 'Updates, support, and suggestions' : null,
```

The exact location depends on how `buildReorderablePriorityItems` renders items. Check the `ListTile` or `PriorityLabel` widget for subtitle support.

- [ ] **Step 2: Run flutter analyze**

```bash
cd apps/plot && flutter analyze
```

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/widget/priorities_list.dart
git commit -m "feat: hardcoded subtitle for Plot App priority"
```

---

### Task 16: Final verification

- [ ] **Step 1: Run full Flutter analysis**

```bash
cd apps/plot && flutter analyze
```

- [ ] **Step 2: Run TypeScript lint**

```bash
pnpm lint
```

- [ ] **Step 3: Verify DB sync**

```bash
pnpm diff-schema-migrations
```

- [ ] **Step 4: Commit any remaining fixes**

```bash
git add -A
git commit -m "fix: address lint issues from Plot App rearchitecture"
```
