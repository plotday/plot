# Onboarding "Connect your tools" — sections + connector categories — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Group the onboarding "Connect your tools" step into Messaging / Calendars / Apps sections driven by a new data-driven connector `category`, and add plan-limit copy with a tappable "Upgrade to Plot Pro" link.

**Architecture:** A new nullable `twist.category` (text) column flows from each connector's `package.json` → CLI deploy → API deploy (`deployTwist`) → `twist` row → `/twists` catalog (automatic, since `get_accessible_twists` does `SELECT twist.*` returning `SETOF twist`) → Flutter `Twist.category`. The onboarding Flutter step buckets connector tiles by that category. No data backfill — existing rows get a category only when their connectors are redeployed; until then they show under **Apps**.

**Tech Stack:** Postgres + Atlas migrations, Cloudflare Workers (Kysely/TypeScript), `@plotday/twister` CLI (TypeScript), Flutter (forui), existing `ShowUpgradeOptions` IAP/web command.

**Context notes for the engineer:**
- Work happens in the **current main checkout** (not a fresh worktree) because `apps/plot/lib/widget/onboarding/onboarding_steps.dart` already has the user's uncommitted step-reordering changes that this work builds on. The local dev DB is on port **54322** (this is the main repo, not a worktree).
- The `public/` directory is a **git submodule**. Changes there (CLI + public connector `package.json`) ship as a **separate PR** with a **changeset**. Commit inside `public/` on a branch, then commit the submodule pointer bump in the main repo.
- Database schema workflow (from `AGENTS.md`): edit `libs/db/schema/`, `pnpm gen-migration -- <name>`, `pnpm apply-migrations` (auto-runs `pnpm types`), commit the regenerated `libs/db/src/types.ts`.
- Never use `flutter format` (repo uses old short-style formatting). Run `cd apps/plot && flutter analyze` to verify Dart.

---

## Task 1: Add `category` column to the `twist` table

**Files:**
- Modify: `libs/db/schema/50-tables/90-twist.sql`
- Generated: `libs/db/migrations/<timestamp>_add_twist_category.sql`
- Regenerated: `libs/db/src/types.ts`

- [ ] **Step 1: Add the column to the schema file**

In `libs/db/schema/50-tables/90-twist.sql`, find the line `    "description" text,` and add the `category` column immediately after it:

```sql
    "description" text,
    -- Connector classification used to group connectors in the UI (e.g. the
    -- onboarding "Connect your tools" step). Known values: 'messaging',
    -- 'calendar'. Open-ended for future categories (e.g. 'tasks',
    -- 'read_later'); null/unknown is treated as a generic app. Set at deploy
    -- time from the connector's package.json `category` field.
    "category" text,
```

- [ ] **Step 2: Generate the migration**

Run: `pnpm gen-migration -- add_twist_category`
Expected: a new file appears under `libs/db/migrations/` adding `category` to `public.twist`. Open it and confirm it is a single `ALTER TABLE "twist" ADD COLUMN "category" text;` (no other unexpected changes, no backfill `UPDATE`s).

- [ ] **Step 3: Apply the migration and regenerate types**

Run: `pnpm apply-migrations`
Expected: migration applies cleanly against the local DB on port 54322; `pnpm types` runs automatically and updates `libs/db/src/types.ts` so `twist.category` becomes `string | null`.

- [ ] **Step 4: Verify schema and migrations are in sync**

Run: `pnpm diff-schema-migrations`
Expected: no differences.
Run: `pnpm --filter @plotday/db run lint`
Expected: passes (types in sync).

- [ ] **Step 5: Verify the column exists**

Run: `psql "$DATABASE_URL" -tAc "SELECT column_name, data_type FROM information_schema.columns WHERE table_name='twist' AND column_name='category';"`
Expected output: `category|text`

- [ ] **Step 6: Commit**

```bash
git add libs/db/schema/50-tables/90-twist.sql libs/db/migrations libs/db/src/types.ts
git commit -m "feat(db): add twist.category column for connector classification

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Persist `category` through the deploy path

**Files:**
- Modify: `workers/api/src/twist/deployment.ts` (interface ~line 34; destructure ~line 89; UPDATE `.set({...})` ~line 280; INSERT `.values({...})` ~line 313)
- Modify: `workers/api/src/sdk/twist.ts` (zod schema ~line 81; destructure ~line 353; two `deployTwist({...})` calls ~line 513 and ~line 622)
- Test: `workers/api/src/twist/deployment.test.ts`

- [ ] **Step 1: Write a failing round-trip test**

Append to `workers/api/src/twist/deployment.test.ts` (the existing file already imports `randomUUID`, `sql`, `Kysely`, `createDb`, `DB`, `Bindings`, `describeDb`, and defines a `Rollback` sentinel — reuse them):

```typescript
async function insertCategoryAndReadBack(category: string | null): Promise<unknown> {
  const db = createDb({ DATABASE_URL } as unknown as Bindings);
  let captured: unknown;
  try {
    await db.transaction().execute(async (trx: Kysely<DB>) => {
      await sql`SET LOCAL session_replication_role = replica`.execute(trx);
      const row = await trx
        .insertInto("twist")
        .values({
          twist_package_id: randomUUID(),
          environment: "personal",
          user_id: randomUUID(),
          name: "Category Test Connector",
          handle: "category-test",
          version: Date.now().toString(),
          category,
        })
        .returning("category")
        .executeTakeFirstOrThrow();
      captured = row.category;
      throw new Rollback();
    });
  } catch (e) {
    if (!(e instanceof Rollback)) throw e;
  } finally {
    await db.destroy();
  }
  return captured;
}

describeDb("deployTwist category write", () => {
  it("persists a connector's category onto the twist row", async () => {
    expect(await insertCategoryAndReadBack("messaging")).toBe("messaging");
  });

  it("writes null when the connector declares no category", async () => {
    expect(await insertCategoryAndReadBack(null)).toBeNull();
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd workers/api && DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54322/postgres" pnpm vitest run src/twist/deployment.test.ts`
Expected: FAIL — Kysely/TypeScript rejects the unknown `category` column (the `twist` insert type has no `category` yet because `db-types.ts` in `workers/api` is not yet regenerated), OR a runtime error. (If it unexpectedly passes because types already include category, that's fine — proceed; the test still guards the column.)

> Note: `workers/api/src/db-types.ts` is the worker's own copy of the DB types. If it does not yet contain `twist.category`, regenerate/refresh it the same way other columns there are maintained (it currently lists `twist` columns around line 1033). If the project generates it via a script, run that; otherwise add `category: string | null;` to the `twist` table interface in `workers/api/src/db-types.ts` so the Kysely types match the DB.

- [ ] **Step 3: Ensure the worker DB types include `category`**

In `workers/api/src/db-types.ts`, find the `twist` table interface (near the `premium: Generated<boolean>;` / `thread_type: string | null;` lines around 1033) and add:

```typescript
  category: string | null;
```

Run the test again: `cd workers/api && DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54322/postgres" pnpm vitest run src/twist/deployment.test.ts`
Expected: PASS (both cases).

- [ ] **Step 4: Thread `category` through `deployTwist`**

In `workers/api/src/twist/deployment.ts`:

(a) In the `DeployTwistOptions` interface, after `logoUrlDark?: string;` (~line 36) add:

```typescript
  /** Connector classification from package.json (e.g. "messaging",
   * "calendar"). Persisted to twist.category; null when unset. */
  category?: string;
```

(b) In the `deployTwist({ ... })` destructure, after `logoUrlDark,` (~line 91) add:

```typescript
  category,
```

(c) In the UPDATE branch `.set({ ... })`, after `logo_url_dark: logoUrlDark ?? null,` (~line 290) add:

```typescript
        category: category ?? null,
```

(d) In the INSERT branch `.values({ ... })`, after `logo_url_dark: logoUrlDark ?? null,` (~line 323) add:

```typescript
        category: category ?? null,
```

- [ ] **Step 5: Parse `category` from the deploy request and pass it through**

In `workers/api/src/sdk/twist.ts`:

(a) In `TwistDeploymentSchema`, after `logoUrlDark: z.string().url().optional(),` (~line 81) add:

```typescript
    category: z.string().optional(),
```

(b) In the destructure of the parsed body, after `logoUrlDark,` (~line 353) add:

```typescript
    category,
```

(c) In the **SSE** `deployTwist({ ... })` call, after `logoUrlDark,` (~line 515) add `category,`.

(d) In the **non-streaming** `deployTwist({ ... })` call, after `logoUrlDark,` (~line 624) add `category,`.

- [ ] **Step 6: Verify build + tests**

Run: `cd workers/api && pnpm lint`
Expected: passes (tsc + eslint clean).
Run: `cd workers/api && DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54322/postgres" pnpm vitest run src/twist/deployment.test.ts`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add workers/api/src/twist/deployment.ts workers/api/src/sdk/twist.ts workers/api/src/db-types.ts workers/api/src/twist/deployment.test.ts
git commit -m "feat(api): persist connector category through the deploy path

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: CLI reads & sends `category` (public submodule)

**Files:**
- Modify: `public/twister/cli/commands/deploy.ts` (metadata extraction ~line 294; requestBody ~line 661)
- Create: `public/.changeset/connector-category.md`

- [ ] **Step 1: Create a branch in the submodule**

```bash
cd public && git checkout -b feat/connector-category && cd ..
```

- [ ] **Step 2: Extract `category` from package.json**

In `public/twister/cli/commands/deploy.ts`, find `const twistLogoUrlDark = packageJson?.logoUrlDark;` (~line 294) and add directly after it:

```typescript
  const twistCategory = packageJson?.category;
```

- [ ] **Step 3: Add `category` to the deploy request body**

In the same file, find the `requestBody = { ... }` assembly (~line 661) and add `category` after `logoUrlDark: twistLogoUrlDark,`:

```typescript
      logoUrlDark: twistLogoUrlDark,
      category: twistCategory,
```

- [ ] **Step 4: Add a changeset**

Create `public/.changeset/connector-category.md`:

```markdown
---
"@plotday/twister": minor
---

Added: connectors can declare a `category` field in package.json (e.g. "messaging", "calendar") that is persisted to the twist record and used to group connectors in the app.
```

- [ ] **Step 5: Validate changeset and build the CLI/package**

Run: `cd public && pnpm validate-changesets`
Expected: passes.
Run: `cd public/twister && pnpm build`
Expected: builds clean (tsc).

- [ ] **Step 6: Commit (inside the submodule)**

```bash
cd public
git add twister/cli/commands/deploy.ts .changeset/connector-category.md
git commit -m "feat(cli): read connector category from package.json and send on deploy

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
cd ..
```

(The submodule-pointer bump in the main repo is committed at the end of Task 4 alongside the public connector edits.)

---

## Task 4: Connector `package.json` sweep

**Files (public submodule, on branch `feat/connector-category`):**
- Modify: `public/connectors/gmail/package.json` → `messaging`
- Modify: `public/connectors/slack/package.json` → `messaging`
- Modify: `public/connectors/google-chat/package.json` → `messaging`
- Modify: `public/connectors/ms-teams/package.json` → `messaging`
- Modify: `public/connectors/google-calendar/package.json` → `calendar`
- Modify: `public/connectors/outlook-calendar/package.json` → `calendar`
- Modify: `public/connectors/apple-calendar/package.json` → `calendar`

**Files (private, main repo):**
- Modify: `connectors/instagram/package.json` → `messaging`
- Modify: `connectors/linkedin/package.json` → `messaging`
- Modify: `connectors/whatsapp/package.json` → `messaging`

- [ ] **Step 1: Add `"category"` after the `"description"` line in each package.json**

For every file listed above, insert a `"category"` field immediately after the existing `"description": "...",` line. Example for `public/connectors/slack/package.json`:

```json
  "description": "Follow Slack channels and DMs, reply in threads, and start new conversations.",
  "category": "messaging",
```

Use `"messaging"` for: gmail, slack, google-chat, ms-teams, instagram, linkedin, whatsapp.
Use `"calendar"` for: google-calendar, outlook-calendar, apple-calendar.
Leave all other connectors (airtable, asana, attio, fellow, github, google-contacts, google-drive, google-tasks, granola, jira, linear, notion, posthog, todoist) **without** a `category` — they fall into Apps.

- [ ] **Step 2: Verify the JSON is valid**

Run:
```bash
for f in public/connectors/{gmail,slack,google-chat,ms-teams,google-calendar,outlook-calendar,apple-calendar}/package.json connectors/{instagram,linkedin,whatsapp}/package.json; do node -e "require('./$f'); console.log('ok $f', require('./$f').category)"; done
```
Expected: every line prints `ok <path> messaging` or `ok <path> calendar` (no JSON parse errors).

- [ ] **Step 3: Commit the public connector edits inside the submodule**

```bash
cd public
git add connectors/gmail/package.json connectors/slack/package.json connectors/google-chat/package.json connectors/ms-teams/package.json connectors/google-calendar/package.json connectors/outlook-calendar/package.json connectors/apple-calendar/package.json
git commit -m "feat(connectors): declare category on messaging and calendar connectors

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
cd ..
```

- [ ] **Step 4: Commit the private connector edits + submodule pointer bump in the main repo**

```bash
git add connectors/instagram/package.json connectors/linkedin/package.json connectors/whatsapp/package.json public
git commit -m "feat(connectors): declare category on private messaging connectors; bump public submodule

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

> The public branch `feat/connector-category` is pushed and opened as a separate PR during finalization (see Task 7). Connectors must be **redeployed** for these categories to land in the `twist` table — that is out of scope here and handled by the normal deploy pipeline.

---

## Task 5: Add `category` to the Flutter `Twist` model

**Files:**
- Modify: `apps/plot/lib/api/twist_api.dart` (fields ~line 41; constructor ~line 67; `fromJson` ~line 142)

- [ ] **Step 1: Add the field**

In `apps/plot/lib/api/twist_api.dart`, in the `Twist` class field list, after `final List<AuthProvider> providers;` (~line 41) add:

```dart
  /// Connector classification used to group connectors in the UI (e.g.
  /// 'messaging', 'calendar'). Null when the connector declares no category.
  final String? category;
```

- [ ] **Step 2: Add the constructor parameter**

In the `const Twist({ ... })` constructor, after `this.providers = const [],` (~line 67) add:

```dart
    this.category,
```

- [ ] **Step 3: Parse it in `fromJson`**

In `Twist.fromJson`, after `providers: providers,` (~line 142) add:

```dart
      category: json['category'] as String?,
```

- [ ] **Step 4: Verify analyze**

Run: `cd apps/plot && flutter analyze lib/api/twist_api.dart`
Expected: no new issues.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/api/twist_api.dart
git commit -m "feat(app): add category field to Twist model

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Section the onboarding tools step + add upgrade copy

**Files:**
- Modify: `apps/plot/lib/widget/onboarding/onboarding_tools.dart` (imports; `build` method's `tools` filter and section rendering; add `_UpgradeCopy` widget)
- Modify: `apps/plot/lib/widget/onboarding/onboarding_steps.dart` (remove unused import line 5)
- Delete: `apps/plot/lib/widget/onboarding/onboarding_calendars.dart`

- [ ] **Step 1: Remove the dead calendar step import**

In `apps/plot/lib/widget/onboarding/onboarding_steps.dart`, delete line 5:

```dart
import 'package:plot/widget/onboarding/onboarding_calendars.dart';
```

- [ ] **Step 2: Delete the now-unused calendar widget**

```bash
git rm apps/plot/lib/widget/onboarding/onboarding_calendars.dart
```

- [ ] **Step 3: Add the upgrade command import to onboarding_tools.dart**

In `apps/plot/lib/widget/onboarding/onboarding_tools.dart`, add to the import group (after the existing `package:plot/...` imports near the top):

```dart
import 'package:plot/command/upgrade.dart' show ShowUpgradeOptions;
```

- [ ] **Step 4: Drop the calendar exclusion so calendars appear in this step**

In `onboarding_tools.dart`, delete the `_calendarPackageIds` constant block (lines ~13-18) entirely:

```dart
const _calendarPackageIds = <String>{
  '2ed4fcf8-6524-410f-b318-f9316e71c8b0', // Google Calendar
  'cf518010-30c1-4594-b3df-295a19d65459', // Outlook Calendar
  '174bbfb4-97f5-49a7-abde-cb237675dd51', // Apple Calendar
};
```

Then update the `tools` filter in `build` to remove the calendar exclusion. Change:

```dart
    final tools =
        twists
            .where(
              (t) =>
                  t.isSource &&
                  t.twistPackageId != null &&
                  !_calendarPackageIds.contains(t.twistPackageId) &&
                  seenPackageIds.add(t.twistPackageId!),
            )
            .toList()
          ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
```

to:

```dart
    final tools =
        twists
            .where(
              (t) =>
                  t.isSource &&
                  t.twistPackageId != null &&
                  seenPackageIds.add(t.twistPackageId!),
            )
            .toList()
          ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
```

And update the `connected` filter to remove its calendar exclusion. Change:

```dart
    final connected =
        _connected
            .where(
              (s) =>
                  s.twistPackageId != null &&
                  !_calendarPackageIds.contains(s.twistPackageId) &&
                  s.enabledCount > 0,
            )
            .toList();
```

to:

```dart
    final connected =
        _connected
            .where((s) => s.twistPackageId != null && s.enabledCount > 0)
            .toList();
```

- [ ] **Step 5: Bucket tools by category and render sections + upgrade copy**

Still in `build`, replace the single `Wrap` of all tools at the bottom of the returned `Column` (the block starting `Wrap(` with `for (final twist in tools)`) with category-bucketed sections followed by the upgrade copy. Add the bucketing right before the `return Column(...)`'s `children:` (i.e., compute the three lists from `tools`):

```dart
        final messaging =
            tools.where((t) => t.category == 'messaging').toList();
        final calendars =
            tools.where((t) => t.category == 'calendar').toList();
        final apps = tools
            .where((t) => t.category != 'messaging' && t.category != 'calendar')
            .toList();
```

Then build the Column children. Replace the existing trailing `Wrap(...)` widget with:

```dart
            _ToolSection(
              title: 'Messaging',
              twists: messaging,
              tileWidth: tileWidth,
              spacing: spacing,
              onTap: _openSetup,
            ),
            _ToolSection(
              title: 'Calendars',
              twists: calendars,
              tileWidth: tileWidth,
              spacing: spacing,
              onTap: _openSetup,
            ),
            _ToolSection(
              title: 'Apps',
              twists: apps,
              tileWidth: tileWidth,
              spacing: spacing,
              onTap: _openSetup,
            ),
            const SizedBox(height: 20),
            const _UpgradeCopy(),
```

- [ ] **Step 6: Add the `_ToolSection` widget**

Add this widget to `onboarding_tools.dart` (e.g. after `_ToolTile`). It renders nothing when its list is empty, otherwise a left-aligned header above a centered `Wrap` of tiles:

```dart
/// A labeled group of connector tiles (e.g. "Messaging"). Renders nothing
/// when [twists] is empty so empty sections disappear.
class _ToolSection extends StatelessWidget {
  const _ToolSection({
    required this.title,
    required this.twists,
    required this.tileWidth,
    required this.spacing,
    required this.onTap,
  });

  final String title;
  final List<Twist> twists;
  final double tileWidth;
  final double spacing;
  final void Function(Twist) onTap;

  @override
  Widget build(BuildContext context) {
    if (twists.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 8, left: 2),
            child: Text(
              title,
              style: const TextStyle(
                color: Color(0xFFFFFFFF),
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
                decoration: TextDecoration.none,
              ),
            ),
          ),
          Wrap(
            spacing: spacing,
            runSpacing: spacing,
            alignment: WrapAlignment.center,
            children: [
              for (final twist in twists)
                SizedBox(
                  width: tileWidth,
                  child: _ToolTile(twist: twist, onTap: () => onTap(twist)),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 7: Add the `_UpgradeCopy` widget**

Add this `StatefulWidget` to `onboarding_tools.dart` (it owns a `TapGestureRecognizer` and disposes it). Do **not** add a `package:flutter/gestures.dart` import — `TapGestureRecognizer` is already re-exported by the existing `package:flutter/widgets.dart` import, and an explicit gestures import would trigger an `unnecessary_import` lint.

Widget:

```dart
/// Plan-limit copy shown beneath the connector sections, with a tappable
/// "Upgrade to Plot Pro" span that opens the standard upgrade flow
/// (StoreKit on App Store builds, web upgrade URL elsewhere — handled by
/// [ShowUpgradeOptions]).
class _UpgradeCopy extends StatefulWidget {
  const _UpgradeCopy();

  @override
  State<_UpgradeCopy> createState() => _UpgradeCopyState();
}

class _UpgradeCopyState extends State<_UpgradeCopy> {
  late final TapGestureRecognizer _recognizer;

  @override
  void initState() {
    super.initState();
    _recognizer = TapGestureRecognizer()..onTap = _onUpgradeTap;
  }

  @override
  void dispose() {
    _recognizer.dispose();
    super.dispose();
  }

  Future<void> _onUpgradeTap() async {
    await ShowUpgradeOptions().run(context);
  }

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        style: const TextStyle(
          color: Color(0xCCFFFFFF),
          fontSize: 13,
          height: 1.5,
          fontWeight: FontWeight.w400,
          decoration: TextDecoration.none,
        ),
        children: [
          const TextSpan(
            text:
                'Add up to five connections on Plot Core, which you can try '
                'for 30 days. You can always use two connections for free. ',
          ),
          TextSpan(
            text: 'Upgrade to Plot Pro',
            style: const TextStyle(
              color: Color(0xFFFFFFFF),
              fontWeight: FontWeight.w600,
              decoration: TextDecoration.underline,
            ),
            recognizer: _recognizer,
          ),
          const TextSpan(text: ' for unlimited connections.'),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }
}
```

- [ ] **Step 8: Verify analyze**

Run: `cd apps/plot && flutter analyze lib/widget/onboarding/`
Expected: no new issues. (Confirm the `Twist` import is already present in `onboarding_tools.dart` via `package:plot/command/twist.dart` / `package:plot/api/twist_api.dart` — the file already references `Twist` in `_ToolTile`, so the type is in scope.)

- [ ] **Step 9: Verify in the running app**

Use the `run-app` skill to launch the macOS app and reach onboarding (or hot-reload the onboarding overlay). Because there is **no backfill**, all local `twist` rows have `category = null` until connectors are redeployed, so by default everything renders under **Apps**. To visually verify the three sections render and bucket correctly, temporarily set categories on a few local rows (local DB only — do **not** commit):

```bash
psql "$DATABASE_URL" -c "UPDATE twist SET category='messaging' WHERE twist_package_id IN ('d8cbc41f-71f5-4cb6-a0bb-3ade462c4084','7176b853-4495-4bba-82ee-645ae5d398d7');"
psql "$DATABASE_URL" -c "UPDATE twist SET category='calendar' WHERE twist_package_id IN ('2ed4fcf8-6524-410f-b318-f9316e71c8b0','cf518010-30c1-4594-b3df-295a19d65459','174bbfb4-97f5-49a7-abde-cb237675dd51');"
```

Confirm: Messaging shows Slack/Gmail, Calendars shows the calendar connectors, Apps shows the rest; empty sections are hidden; the upgrade copy renders and tapping "Upgrade to Plot Pro" opens the upgrade picker (`ShowUpgradeOptions`).

- [ ] **Step 10: Commit**

```bash
git add apps/plot/lib/widget/onboarding/onboarding_tools.dart apps/plot/lib/widget/onboarding/onboarding_steps.dart
git rm apps/plot/lib/widget/onboarding/onboarding_calendars.dart
git commit -m "feat(app): section onboarding connectors into Messaging/Calendars/Apps + upgrade copy

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Finalize

- [ ] **Step 1: Run the finalization checklist**

Invoke the `/finalize` skill. It covers lint across changed packages, backwards-compat, error capture, docs (`docs/updates.md` / `docs/features.md`), and the public-submodule PR + changeset.

- [ ] **Step 2: Update user-facing docs**

Add a short bullet to the top of `docs/updates.md` (plain language), e.g.:

```markdown
- The onboarding "Connect your tools" step now groups your connectors into Messaging, Calendars, and Apps, and shows your plan's connection limits with a quick upgrade option.
```

- [ ] **Step 3: Open the public submodule PR**

Push the `public` branch `feat/connector-category` and open a PR (separate from the main-repo change), referencing the changeset. The main-repo commit from Task 4 already bumped the submodule pointer to the branch tip; re-bump after the public PR merges if its tip moves.

- [ ] **Step 4: Final verification**

Run: `cd apps/plot && flutter analyze` (expect no new issues)
Run: `cd workers/api && pnpm lint` (expect clean)
Run: `pnpm diff-schema-migrations` (expect no differences)

---

## Self-review notes

- **Spec coverage:** §1 data model → Tasks 1,2,3,5; §2 no backfill → Task 1 (column only, explicit note); §3 connector sweep → Task 4; §4 UI sections → Task 6; §5 upgrade copy → Task 6 (`_UpgradeCopy` → `ShowUpgradeOptions`). `/twists` carrying `category` is automatic via `get_accessible_twists` `SELECT twist.*` (no task needed; called out in Architecture).
- **Type consistency:** `category` is `string | null` in DB/worker types and `String?` in Dart; the `_ToolSection`/`_UpgradeCopy`/`_openSetup(Twist)` signatures match their call sites in Task 6.
- **No backfill:** confirmed — migration adds only the nullable column; verification in Task 6 Step 9 uses throwaway local `UPDATE`s, not a committed migration.
