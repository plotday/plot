# Focus Roles — Plan 5: Onboarding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development / superpowers:executing-plans. Steps use checkbox (`- [ ]`).

**Goal:** Every new user gets a default **Personal** role at activation (the root adopted as its Inbox), and the onboarding flow gains an early "Where do you want to use Plot first?" step that names that role from the user's answer.

**Architecture:** Server `activate_invited_user` creates the Personal role + adopts the root as its Inbox (mirroring Plan 1's backfill, but for new users) — guaranteeing every user always has ≥1 role and no role-less focus. The onboarding step is a `FullScreenStep` whose `contentBuilder` is a single-select (Work/Personal/Volunteering/School/Other) with a conditional text input; its `onBeforeNext` renames the user's existing default role (keeping theme 0). It does **not** create a second role, so new users stay single-role (flat sidebar).

**Tech Stack:** Postgres function (`libs/db/schema/60-functions/`) + expand migration; Flutter onboarding (`apps/plot/lib/widget/onboarding/`, `state/onboarding*.dart`); `flutter analyze` + `diff-schema-migrations` gates.

**This plan is Plan 5 of 6.** Plans 1–4 landed. Branch `focus-roles`.

---

## Pre-flight
```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/focus-roles
source .worktree-db && export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"
[ "$PORT" != "54322" ] && echo "worktree DB ok: $PORT" || { echo "ABORT"; exit 1; }
```

## File Structure
- **Modify** `libs/db/schema/60-functions/activate_invited_user.sql` — create the Personal role + adopt root as Inbox.
- **Generate** an expand migration for the function change.
- **Create** `apps/plot/lib/widget/onboarding/onboarding_role.dart` — the role-question content widget + a small shared selection holder.
- **Modify** `apps/plot/lib/widget/onboarding/onboarding_steps.dart` — insert the role step + its `onBeforeNext`.
- **Modify** `apps/plot/lib/state/onboarding.dart` (only if the second-device skip needs broadening — see Task 3).

---

## Task 1: Activation creates the Personal role + Inbox

**Files:** `libs/db/schema/60-functions/activate_invited_user.sql`

- [ ] **Step 1: Extend the function**

Read the full function. It creates the root priority (`INSERT INTO public.priority (created_by, user_id, title, path, color) VALUES (p_user_id, p_user_id, 'Everything', v_new_path, 0) RETURNING id INTO v_root_priority_id;`). Add a declaration `v_default_role_id uuid;` and, **immediately after** that root INSERT, create the Personal role and adopt the root as its Inbox:

```sql
    -- Every user gets a default "Personal" role (theme 0); the root becomes its
    -- Inbox. Mirrors the focus-roles backfill so new users match existing ones.
    INSERT INTO public.role (created_by, user_id, name, color)
        VALUES (p_user_id, p_user_id, 'Personal', 0)
    RETURNING id INTO v_default_role_id;

    UPDATE public.priority
        SET role_id = v_default_role_id, is_inbox = TRUE
        WHERE id = v_root_priority_id;
```

> The server table is `public.role` (NOT `user_role`, which is only the client Drift table / `user.role` view). The `default_role_user_id` trigger fills `order`. The root's colour is already 0 and notifications NULL, so the Inbox trivially follows the role.

- [ ] **Step 2: Generate + apply the migration**
```bash
pnpm gen-migration -- activation_default_role
pnpm apply-migrations
pnpm diff-schema-migrations   # synced
```

- [ ] **Step 3: Smoke-test activation for a fresh user**
```bash
psql "$DATABASE_URL" -tAc "
  DO \$\$
  DECLARE u uuid; res jsonb;
  BEGIN
    INSERT INTO \"user\" DEFAULT VALUES RETURNING id INTO u;  -- adapt to the real user insert shape
    res := public.activate_invited_user(u);
    ASSERT (SELECT count(*) FROM role WHERE user_id=u AND name='Personal')=1, 'no personal role';
    ASSERT (SELECT count(*) FROM priority WHERE user_id=u AND is_inbox)=1, 'no inbox';
    ASSERT (SELECT role_id FROM priority WHERE user_id=u AND is_inbox) =
           (SELECT id FROM role WHERE user_id=u), 'inbox not in role';
    RAISE EXCEPTION 'rollback smoke';
  END \$\$;"
```
Expected: ends with `rollback smoke` (assertions passed, nothing persisted). If the bare `INSERT INTO "user" DEFAULT VALUES` fails (required columns), adapt it to how a user row is normally created (check the `user` table / an existing test fixture); the point is to exercise `activate_invited_user` once and assert role+inbox.

---

## Task 2: Onboarding role-question step

**Files:** Create `apps/plot/lib/widget/onboarding/onboarding_role.dart`; Modify `apps/plot/lib/widget/onboarding/onboarding_steps.dart`

- [ ] **Step 1: Read the patterns**

Read `onboarding_steps.dart` (the `FullScreenStep` fields incl. `onBeforeNext` + `OnboardingSteps.all`), `onboarding_full_screen.dart` (how `contentBuilder` renders below the body), `onboarding_tools.dart` + `onboarding_hoverable.dart` (the option-tile idiom: `OnboardingHoverable` + `AnimatedContainer`), and `store/role.dart` (`Role.all`, `Role.create`, `copyWith`, `save`). Note `_handleNext` in `onboarding_overlay.dart` awaits `onBeforeNext` and toasts on error.

- [ ] **Step 2: Build the role-question content widget + selection holder**

Create `apps/plot/lib/widget/onboarding/onboarding_role.dart`:

```dart
// A tiny mutable holder shared between the step's contentBuilder (which writes
// it) and the step's onBeforeNext (which reads it). One instance per onboarding
// session — OnboardingSteps.all is built once in OnboardingBloc.start().
class OnboardingRoleSelection {
  RoleOption option = RoleOption.personal;
  String text = '';
}

enum RoleOption { work, personal, volunteering, school, other }

extension RoleOptionMeta on RoleOption {
  String get label => switch (this) {
    RoleOption.work => 'Work',
    RoleOption.personal => 'Personal',
    RoleOption.volunteering => 'Volunteering',
    RoleOption.school => 'School',
    RoleOption.other => 'Other',
  };
  // Null = no follow-up prompt (Personal, School).
  String? get prompt => switch (this) {
    RoleOption.work => 'Where do you work?',
    RoleOption.volunteering => 'Where do you volunteer?',
    RoleOption.other => 'What should we call this role?',
    _ => null,
  };
  String? get placeholder => switch (this) {
    RoleOption.work => 'Acme Co',
    RoleOption.volunteering => 'The Kindness Project',
    RoleOption.other => 'Superhero',
    _ => null,
  };
  /// The resulting role name given the typed [text].
  String roleName(String text) {
    final t = text.trim();
    return switch (this) {
      RoleOption.personal => 'Personal',
      RoleOption.school => 'School',
      _ => t.isNotEmpty ? t : label, // Work/Volunteering/Other fall back to the label
    };
  }
}
```

Then a `StatefulWidget` `OnboardingRoleContent({required OnboardingRoleSelection selection})` that renders:
- The 5 options as selectable tiles (reuse `OnboardingHoverable` + `AnimatedContainer`, styled like `_ToolTile`; the selected one gets an accent border/background). Tapping sets `selection.option` + `setState`.
- Below them, when `selection.option.prompt != null`, a text field (forui `TextField`/`FTextField`, white-on-overlay to match the onboarding aesthetic) with the option's `prompt` as label and `placeholder` as hint, writing to `selection.text` on change (and clearing/ignoring `text` when an option without a prompt is selected).

Keep it self-contained; no Bloc reads (it's onboarding content). Match the onboarding visual style (white text/tiles on the coloured background) used by `onboarding_tools.dart`.

- [ ] **Step 3: Insert the step + onBeforeNext into `OnboardingSteps.all`**

In `onboarding_steps.dart`, change `static List<OnboardingStep> get all` to construct a shared `OnboardingRoleSelection` and insert the role step as the **first interactive step** — immediately after the "Your best work every day" welcome splash (index 1), before "Connect your tools":

```dart
static List<OnboardingStep> get all {
  final roleSelection = OnboardingRoleSelection();
  return [
    const FullScreenStep(title: "Your best work\nevery day", body: "...", background: ThemeColor(0)),
    FullScreenStep(
      title: 'Where do you want to use Plot first?',
      body: 'Plot organizes your work by role. Pick the one to start with — you can add more later.',
      background: const ThemeColor(2),
      contentBuilder: (context) => OnboardingRoleContent(selection: roleSelection),
      onBeforeNext: (context) => _commitRole(roleSelection),
    ),
    FullScreenStep(title: 'Connect your tools', /* ...unchanged... */),
    // ...the remaining steps unchanged...
  ];
}

static Future<void> _commitRole(OnboardingRoleSelection sel) async {
  final name = sel.option.roleName(sel.text);
  final roles = await Role.all();
  if (roles.isNotEmpty) {
    // Rename the user's existing default role (keep theme 0). The Inbox follows.
    await roles.first.copyWith(name: name).save();
  } else {
    // Edge: no role synced yet (older activation / sync lag) — create one.
    // The server auto-creates its Inbox on insert.
    await Role.create(name: name, color: const ThemeColor(0)).save();
  }
}
```

> Throwing inside `_commitRole` surfaces the generic onboarding error toast and blocks advancing — acceptable for a transient failure. Because `roleName` always returns a non-empty default, there is no hard validation gate (Next always proceeds with a sensible name).

- [ ] **Step 4: Analyze**

Run: `cd apps/plot && flutter analyze`
Expected: no new errors.

---

## Task 3: Keep the second-device skip working

**Files:** `apps/plot/lib/state/onboarding.dart` (only if needed)

- [ ] **Step 1: Determine whether `onboardingCompleted` syncs across devices**

`OnboardingBloc.start()` skips when `settings.onboardingCompleted == true`, else when `Priority.hasNonRoot()` (a non-root focus exists). In the new model the role step renames the role but does NOT create a non-root focus, so a user who onboards and creates no focus has only the root/Inbox → `hasNonRoot()` is false. If `onboardingCompleted` does NOT sync, a second device would re-run onboarding.

Run: `grep -rn "onboardingCompleted\|UserSettingsEntity" apps/plot/lib/store/user_settings.dart apps/plot/lib/store/ | head` and read how `UserSettingsEntity` syncs (is it a synced `BaseTable`, or local-only?).

- [ ] **Step 2: If `onboardingCompleted` is local-only, broaden the cross-device signal**

If settings are local-only (so `hasNonRoot()` is the real cross-device signal), it no longer fires after a role-only onboarding. Broaden it: a user who has used Plot will have **renamed their default role** away from the seeded 'Personal' OR created additional roles/focuses. Add a helper and use it in `start()` alongside `hasNonRoot()`:

```dart
// In start(), replace the hasNonRoot() short-circuit condition with:
if (await Priority.hasNonRoot() || await Role.hasConfigured()) { ... }
```
where `Role.hasConfigured()` returns true when the user has >1 role, OR exactly one role whose name != 'Personal' (i.e. they answered the onboarding question). Add `hasConfigured()` to `store/role.dart`.

> If `onboardingCompleted` DOES sync cross-device, skip Step 2 entirely — note that and leave `start()` unchanged.

- [ ] **Step 3: Analyze**

Run: `cd apps/plot && flutter analyze`
Expected: no new errors.

---

## Task 4: Verify + Commit

- [ ] **Step 1: Gates**
```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/focus-roles
source .worktree-db && export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres"
pnpm diff-schema-migrations            # synced
pnpm --filter @plotday/db run lint     # types up to date
cd apps/plot && flutter analyze        # no new errors
```

- [ ] **Step 2: run-app (best-effort)**

Via the `run-app` skill, for a fresh/onboarding user: confirm the role question appears as the first interactive step, picking "Work" reveals "Where do you work?" (placeholder "Acme Co"), and advancing renames the sidebar's single role (no second role appears; sidebar stays flat). If blocked by Clerk, document and rely on analyze + the activation smoke test.

- [ ] **Step 3: Commit**
```bash
cd /Users/kris.braun/code/plot/.claude/worktrees/focus-roles
git add -A
git commit --no-verify -m "feat: onboarding role question + default Personal role at activation

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-review (run before execution)
- **Spec coverage:** activation creates Personal role + adopts root Inbox ✓ (Task 1); onboarding asks "Where do you want to use Plot first?" with Work/Personal/Volunteering/School/Other + conditional prompts (Work→"Where do you work?"/Acme Co, Volunteering→"Where do you volunteer?"/The Kindness Project, Other→"What should we call this role?"/Superhero, Personal/School skip) ✓ (Task 2 Step 2); names the role from the answer, theme 0, renames the existing default (no second role) ✓ (Task 2 Step 3); second-device skip preserved ✓ (Task 3). The path/root teardown is Plan 6.
- **No placeholders:** the role widget + holder + `_commitRole` + activation SQL are concrete; the "read X / verify sync behavior" steps (Task 2 Step 1, Task 3 Step 1) are genuine investigation points.
- **Type consistency:** `OnboardingRoleSelection`/`RoleOption`/`OnboardingRoleContent`/`_commitRole`/`roleName` and `public.role` (server) vs `user_role` (client) used consistently.
- **Edge:** `_commitRole` falls back to `Role.create` if no role has synced yet (older activation / lag), which the server backstops by auto-creating the Inbox.
