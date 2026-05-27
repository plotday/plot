# Twist handle/threadType + connection-field unification — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the twist picker out of `NoteEditor` and into the connection field on `NewThreadPage`. Split twist identity into `handle` (at-mentions/attributions) and `threadType` (connection picker label). At-mentioning a twist also selects it as the connection.

**Architecture:** Add `handle` (NOT NULL, defaults to twist `name`) and `thread_type` (nullable) columns to the `twist` table, expose via `user.twist`, propagate through `TwistInstance` on the client. Flutter: introduce `TwistConnectionChoice` in the existing sealed `ConnectionChoice` hierarchy, include twists in `ConnectionPickerModal`, wire selection through the existing `_selectTwist` path. Remove the redundant twist button from the `NoteEditor` bottom bar. Hook into `Editor`'s mention popover so completing a twist mention fires a parent callback that sets the connection.

**Tech Stack:** Postgres + Atlas migrations, Cloudflare Workers (Hono/Kysely), `@plotday/twister` (TypeScript SDK + CLI), Flutter (Drift, flutter_bloc, super_editor).

**Spec:** `docs/superpowers/specs/2026-05-27-twist-handle-thread-type-design.md`

---

## Task 1: Add `handle` + `thread_type` to the `twist` table schema

**Files:**
- Modify: `libs/db/schema/50-tables/90-twist.sql`
- Modify: `libs/db/schema/90-user-schema/32-twist.sql`

- [ ] **Step 1: Add columns to the `twist` table**

In `libs/db/schema/50-tables/90-twist.sql`, add the two columns after `"name" text NOT NULL,` (line 20):

```sql
    "name" text NOT NULL,
    -- At-mention / attribution label. Defaults to `name` when not supplied
    -- by the twist's package.json. Distinct from `name` (settings/marketplace
    -- label) so a twist can read as "@Plot" in the editor while showing as
    -- "Plot AI Assistant" in settings.
    "handle" text NOT NULL,
    -- When non-null, this twist appears as a choice in the new-thread
    -- connection picker with this label (e.g. "Plot AI chat"). When null
    -- the twist is not offered as a chat target.
    "thread_type" text,
    "description" text,
```

- [ ] **Step 2: Expose the new columns from `user.twist`**

In `libs/db/schema/90-user-schema/32-twist.sql`, add `t.handle` and `t.thread_type` to the SELECT (after `t.logo_url_dark` on line 38):

```sql
    t.logo_url,
    t.logo_url_dark,
    t.handle,
    t.thread_type,
    (
```

- [ ] **Step 3: Generate the migration**

Run from repo root:

```bash
pnpm gen-migration -- add_twist_handle_thread_type
```

Expected: creates a new file under `libs/db/migrations/` adding both columns and recreating the view.

- [ ] **Step 4: Edit the generated migration to backfill `handle` and bump seq**

Open the new file in `libs/db/migrations/`. Two adjustments:

a) The generated `ALTER TABLE twist ADD COLUMN handle text NOT NULL` will fail on existing rows. Change to a 3-step add/backfill/set-not-null pattern. Insert this BEFORE the `ALTER TABLE ... ADD COLUMN "handle" text NOT NULL` statement, and remove the NOT NULL from the original ADD:

```sql
ALTER TABLE "public"."twist" ADD COLUMN "handle" text;
UPDATE "public"."twist" SET "handle" = "name" WHERE "handle" IS NULL;
ALTER TABLE "public"."twist" ALTER COLUMN "handle" SET NOT NULL;
```

b) At the very end of the migration, add a one-shot `seq` bump so existing `user.twist` rows re-emit through sync (per `libs/db/AGENTS.md` "Bump on schema changes that add view columns"):

```sql
-- Re-emit existing twist rows so clients pick up handle + thread_type.
UPDATE "public"."twist" SET updated_at = now();
```

- [ ] **Step 5: Recompute Atlas migration hash**

```bash
cd libs/db && atlas migrate hash --dir file://migrations
```

Expected: updates `atlas.sum`. CI fails without this.

- [ ] **Step 6: Apply the migration locally**

```bash
pnpm apply-migrations
```

Expected: applies cleanly, regenerates `libs/db/src/types.ts` (`pnpm types` runs automatically on non-CI).

- [ ] **Step 7: Verify schema and types are in sync**

```bash
pnpm diff-schema-migrations && pnpm --filter @plotday/db run lint
```

Expected: both exit zero (no diff, types up to date).

- [ ] **Step 8: Commit**

```bash
git add libs/db/schema/50-tables/90-twist.sql \
        libs/db/schema/90-user-schema/32-twist.sql \
        libs/db/migrations/ \
        libs/db/src/types.ts
git commit -m "Add twist.handle and twist.thread_type columns"
```

---

## Task 2: Wire `handle`/`threadType` through the API deployment path

**Files:**
- Modify: `workers/api/src/twist/deployment.ts`

- [ ] **Step 1: Add the fields to `DeployTwistOptions`**

In `workers/api/src/twist/deployment.ts`, extend the interface (around line 19):

```ts
export interface DeployTwistOptions {
  env: Bindings;
  ctx: { exports: ExecutionContext["exports"] };
  db: Kysely<DB>;
  twistPackageId: string;
  publisherId: number | null;
  userId: string | null;
  input: DeploymentInput;
  environment: TwistEnvironment;
  name: string;
  /** At-mention / attribution label. Defaults to `name`. */
  handle?: string;
  /** Optional connection-picker label. When set the twist appears in the
   * new-thread connection picker. */
  threadType?: string | null;
  description?: string;
  logoUrl?: string;
  logoUrlDark?: string;
  userName?: string;
  userEmail?: string;
  dryRun?: boolean;
  onProgress?: (message: string) => void;
  source?: "code" | "spec";
}
```

- [ ] **Step 2: Destructure the new fields**

In the `deployTwist` signature around line 59, add `handle` and `threadType`:

```ts
export async function deployTwist({
  env,
  ctx,
  db,
  twistPackageId,
  publisherId,
  userId,
  input,
  environment,
  name,
  handle,
  threadType,
  description,
  logoUrl,
  logoUrlDark,
  dryRun = false,
  onProgress,
  source: deployedFrom = "code",
}: DeployTwistOptions): Promise<DeployTwistResult> {
```

- [ ] **Step 3: Write `handle` and `thread_type` on the UPDATE branch**

In the `db.updateTable("twist").set({ ... })` block (around line 252), add the two fields. `handle` defaults to `name` when the caller omits it:

```ts
    twist = await db
      .updateTable("twist")
      .set({
        name,
        handle: handle ?? name,
        thread_type: threadType ?? null,
        description,
        version,
        permissions: JSON.stringify(twistPermissions),
        options_schema: optionsSchema ? JSON.stringify(optionsSchema) : null,
        is_source: providers.length > 0 || isNoProviderConnector,
        shared: sourceProvider?.shared ?? false,
        key_option: sourceProvider?.keyOption ?? null,
        logo_url: logoUrl ?? null,
        logo_url_dark: logoUrlDark ?? null,
        multiple_instances: multipleInstances,
      })
```

- [ ] **Step 4: Same on the INSERT branch**

In the `db.insertInto("twist").values({ ... })` block (around line 277), add the same two fields:

```ts
    twist = await db
      .insertInto("twist")
      .values({
        twist_package_id: twistPackageId,
        publisher_id: environment === "personal" ? null : publisherId,
        user_id: environment === "personal" ? userId : null,
        environment,
        name,
        handle: handle ?? name,
        thread_type: threadType ?? null,
        description,
        version,
        permissions: JSON.stringify(newTwistPermissions),
        options_schema: optionsSchema ? JSON.stringify(optionsSchema) : null,
        is_source: providers.length > 0 || isNoProviderConnector,
        shared: sourceProvider?.shared ?? false,
        key_option: sourceProvider?.keyOption ?? null,
        logo_url: logoUrl ?? null,
        logo_url_dark: logoUrlDark ?? null,
        multiple_instances: multipleInstances,
      })
```

- [ ] **Step 5: Locate the deploy endpoint handler and forward fields**

Find the HTTP handler that calls `deployTwist`. Search:

```bash
grep -rn "deployTwist(" workers/api/src --include="*.ts"
```

For each call site (typically `workers/api/src/app/twists.ts` and possibly `workers/api/src/twist/tools/twists.ts`), extract `handle` and `threadType` from the request body and pass them through. Example for the HTTP handler:

```ts
await deployTwist({
  env: c.env,
  ctx: c.executionCtx,
  db: c.var.db,
  twistPackageId,
  publisherId,
  userId,
  input: { module, sourcemap },
  environment,
  name,
  handle: body.handle,
  threadType: body.threadType ?? null,
  description,
  logoUrl: body.logoUrl,
  logoUrlDark: body.logoUrlDark,
  // ...
});
```

- [ ] **Step 6: Lint the API worker**

```bash
pnpm --filter @plotday/api lint
```

Expected: zero errors.

- [ ] **Step 7: Commit**

```bash
git add workers/api/src/twist/deployment.ts workers/api/src/app/twists.ts workers/api/src/twist/tools/twists.ts
git commit -m "Forward twist handle and threadType through deploy path"
```

(Only stage files that were actually modified — the second/third path depends on what the grep turned up.)

---

## Task 3: Read `handle`/`threadType` from package.json in the Twister CLI

**Files:**
- Modify: `public/twister/cli/commands/deploy.ts`
- Create: `public/.changeset/twist-handle-thread-type.md`

This task touches the public submodule. Work inside `public/` and commit there first (separate PR), then the main repo bumps the submodule reference later.

- [ ] **Step 1: Extract `handle` and `threadType` from package.json**

In `public/twister/cli/commands/deploy.ts`, find the metadata extraction block (currently around line 287):

```ts
  const twistName = packageJson?.displayName;
  const twistDescription = packageJson?.description;
  const twistLogoUrl = packageJson?.logoUrl;
  const twistLogoUrlDark = packageJson?.logoUrlDark;
  const twistPublisher = packageJson?.publisher;
  const twistPublisherUrl = packageJson?.publisherUrl;
```

Add the two new fields:

```ts
  const twistName = packageJson?.displayName;
  const twistHandle = packageJson?.handle;
  const twistThreadType = packageJson?.threadType;
  const twistDescription = packageJson?.description;
  const twistLogoUrl = packageJson?.logoUrl;
  const twistLogoUrlDark = packageJson?.logoUrlDark;
  const twistPublisher = packageJson?.publisher;
  const twistPublisherUrl = packageJson?.publisherUrl;
```

- [ ] **Step 2: Extend the `requestBody` type and value**

Find the `requestBody` declaration (around line 618) and add the two fields:

```ts
  let requestBody: {
    module: string;
    sourcemap?: string;
    name: string;
    handle?: string;
    threadType?: string;
    description?: string;
    logoUrl?: string;
    logoUrlDark?: string;
    environment: string;
    publisherId?: number;
    dryRun?: boolean;
  };
```

Then in the assignment (around line 655):

```ts
    requestBody = {
      module: moduleContent,
      sourcemap: sourcemapContent,
      name: deploymentName!,
      handle: twistHandle,
      threadType: twistThreadType,
      description: deploymentDescription,
      logoUrl: twistLogoUrl,
      logoUrlDark: twistLogoUrlDark,
      environment: environment,
      publisherId,
      dryRun: options.dryRun,
    };
```

- [ ] **Step 3: Add a changeset for Twister**

Create `public/.changeset/twist-handle-thread-type.md`:

```markdown
---
"@plotday/twister": minor
---

Added: `handle` and `threadType` fields in twist `package.json`. `handle` is the at-mention / attribution label (defaults to `displayName`). `threadType`, when present, makes the twist appear in the new-thread connection picker with the given label.
```

- [ ] **Step 4: Validate the changeset**

```bash
cd public && pnpm validate-changesets
```

Expected: zero errors.

- [ ] **Step 5: Build Twister to surface any type errors**

```bash
cd public/twister && pnpm build
```

Expected: clean build.

- [ ] **Step 6: Commit inside the public submodule**

```bash
cd public
git add twister/cli/commands/deploy.ts .changeset/twist-handle-thread-type.md
git commit -m "Add handle and threadType fields to twist package.json"
```

(The main repo's submodule reference bump comes after Task 4 lands so both ends move together.)

---

## Task 4: Declare `handle` and `threadType` on the Plot twist + bump submodule

**Files:**
- Modify: `twists/plot/package.json`
- Modify: `public` (submodule reference)

- [ ] **Step 1: Add the fields to `twists/plot/package.json`**

Open `twists/plot/package.json` and add `handle` and `threadType` after `displayName`:

```json
{
  "name": "@plotday/twist-plot",
  "plotTwistId": "0199b6f4-ae64-7718-8a02-44716f30358f",
  "displayName": "Plot",
  "handle": "Plot",
  "threadType": "Plot AI chat",
  "description": "Support setting up, using, and automating Plot",
  "logoUrl": "https://plot.day/assets/plot-icon.svg",
  "publisher": "Plot",
  "publisherUrl": "https://plot.day",
  ...
}
```

- [ ] **Step 2: Commit the package.json change**

```bash
git add twists/plot/package.json
git commit -m "Set Plot twist handle and threadType"
```

- [ ] **Step 3: Bump the public submodule reference**

The submodule commit from Task 3 needs to be referenced from the main repo:

```bash
git add public
git commit -m "Bump public submodule with twist handle/threadType CLI support"
```

---

## Task 5: Add `handle` + `threadType` to the Flutter `TwistInstance` model

**Files:**
- Modify: `apps/plot/lib/store/twist_instance.dart`
- Modify: `apps/plot/lib/store/store.dart` (drift migration)

- [ ] **Step 1: Add the two columns to the Drift table**

In `apps/plot/lib/store/twist_instance.dart`, add the columns right after `TextColumn get name => text()();` (line 16):

```dart
  TextColumn get name => text()();
  TextColumn get handle => text().withDefault(const Constant(''))();
  TextColumn get threadType => text().nullable()();
  TextColumn get accountLabel => text().nullable()();
```

`handle` gets `withDefault('')` so the Drift migration is non-destructive; the sync layer immediately overwrites it from the server payload.

- [ ] **Step 2: Pass the new fields into the `TwistInstance` constructor**

Still in `apps/plot/lib/store/twist_instance.dart`, update the constructor (around line 212):

```dart
  TwistInstance(TwistInstanceRow row)
    : super(
        id: row.id,
        twistId: row.twistId,
        twistEnvironment: row.twistEnvironment,
        teamId: row.teamId,
        draft: row.draft,
        isSource: row.isSource,
        shared: row.shared,
        keyOption: row.keyOption,
        name: row.name,
        handle: row.handle,
        threadType: row.threadType,
        accountLabel: row.accountLabel,
        config: row.config,
        linkTypes: row.linkTypes,
        logoUrl: row.logoUrl,
        logoUrlDark: row.logoUrlDark,
        defaultMentionCreated: row.defaultMentionCreated,
        defaultMentionMentioned: row.defaultMentionMentioned,
        userConnected: row.userConnected,
        isBuiltin: row.isBuiltin,
        multipleInstances: row.multipleInstances,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        archivedAt: row.archivedAt,
        pending: row.pending,
      );
```

- [ ] **Step 3: Add a `mentionLabel` getter**

After `displayName()` in `apps/plot/lib/store/twist_instance.dart` (around line 295), add:

```dart
  /// At-mention / attribution label for this twist.
  ///
  /// Mirrors [displayName] but uses [handle] (the package-level mention
  /// name) as the base instead of [name] (the per-install display name).
  /// Sources keep using their per-connection [accountLabel] suffix.
  /// Multi-instance and scope-disambiguation rules match [displayName] so
  /// the label is unique across the user's installed twists.
  String mentionLabel({
    required List<TwistInstance> allInstances,
    String? teamName,
  }) {
    final base = handle.isEmpty ? name : handle;
    if (isSource) {
      if (accountLabel != null && accountLabel!.isNotEmpty) {
        return '$base ($accountLabel)';
      }
      return base;
    }
    if (multipleInstances) return base;
    final hasSibling = allInstances.any(
      (other) =>
          other.id != id &&
          other.twistId == twistId &&
          other.archivedAt == null,
    );
    if (!hasSibling) return base;
    final scopeLabel = teamId == null ? 'Personal' : (teamName ?? 'Team');
    return '$base ($scopeLabel)';
  }
```

- [ ] **Step 4: Add the Drift migration step**

In `apps/plot/lib/store/store.dart`:

a) Bump `schemaVersion` from 343 to 344 (line 2391):

```dart
  int get schemaVersion => 344;
```

b) Append a migration step at the end of `onUpgrade`, after the last existing `if (from < 343)` block (search for the highest `from < N` in `Store.migration.onUpgrade`):

```dart
    if (from < 344) {
      await m.addColumn(twistInstances, twistInstances.handle);
      await m.addColumn(twistInstances, twistInstances.threadType);
    }
```

- [ ] **Step 5: Update the sync fromBase mapper if needed**

`TwistInstancesBase.fromBase` (line 40) does not need changes — Drift's `fromJson` picks up the new columns automatically as long as the server sends them.

- [ ] **Step 6: Regenerate Drift code**

```bash
cd apps/plot && flutter pub run build_runner build --delete-conflicting-outputs
```

Expected: regenerates `apps/plot/lib/store/store.g.dart`.

- [ ] **Step 7: Verify with `flutter analyze`**

```bash
cd apps/plot && flutter analyze lib/store/twist_instance.dart lib/store/store.dart lib/store/store.g.dart
```

Expected: zero errors.

- [ ] **Step 8: Commit**

```bash
git add apps/plot/lib/store/twist_instance.dart apps/plot/lib/store/store.dart apps/plot/lib/store/store.g.dart
git commit -m "Add handle and threadType to TwistInstance"
```

---

## Task 6: Add `TwistConnectionChoice` to the connection picker

**Files:**
- Modify: `apps/plot/lib/widget/compose/connection_choice.dart`

- [ ] **Step 1: Add the new sealed-class case**

Replace the contents of `apps/plot/lib/widget/compose/connection_choice.dart`:

```dart
import 'package:plot/store/store.dart' show CreateLinkUserAction, TwistInstance;
import 'package:plot/widget/connection_targets.dart' show CreateTarget;

/// A selectable connection on the compose surface. Either a real
/// [CreateTarget] (Slack channel, Linear team, …), the synthetic
/// "Plot thread" choice that just clears any existing connection, or a
/// [TwistInstance] (chat with a twist — Plot AI, etc.).
sealed class ConnectionChoice {
  String get key;
  String get label;
  String? get logo;
  String? get logoDark;
  String get searchText;

  /// Returns the [CreateLinkUserAction] to attach to the draft, or null
  /// for the Plot-thread / twist choices (which use other state to track
  /// selection — twist selection lives in `thread.icon` via
  /// `_selectTwist`).
  CreateLinkUserAction? toUserAction();

  static const PlotThreadChoice plotThread = PlotThreadChoice._();

  /// Wrap a real [CreateTarget] as a choice.
  factory ConnectionChoice.target(CreateTarget target) =
      TargetConnectionChoice;

  /// Wrap a [TwistInstance] as a choice. Only twists whose `threadType`
  /// is non-null should be wrapped — the picker filters before calling
  /// this constructor.
  factory ConnectionChoice.twist(
    TwistInstance twist, {
    required List<TwistInstance> allInstances,
    String? teamName,
  }) = TwistConnectionChoice;
}

/// The synthetic "Plot thread" sentinel. Selecting it clears any
/// [CreateLinkUserAction] on the draft and clears any selected twist.
class PlotThreadChoice implements ConnectionChoice {
  const PlotThreadChoice._();

  @override
  String get key => 'plot:thread';

  @override
  String get label => 'Plot thread';

  @override
  String? get logo => null;

  @override
  String? get logoDark => null;

  @override
  String get searchText => 'plot thread';

  @override
  CreateLinkUserAction? toUserAction() => null;
}

/// A real [CreateTarget] wrapped as a [ConnectionChoice].
class TargetConnectionChoice implements ConnectionChoice {
  TargetConnectionChoice(this.target);

  final CreateTarget target;

  @override
  String get key => target.key;

  @override
  String get label => target.chipLabel;

  @override
  String? get logo => target.linkType.logo;

  @override
  String? get logoDark => target.linkType.logoDark;

  @override
  String get searchText => target.searchText;

  @override
  CreateLinkUserAction? toUserAction() => target.toUserAction();
}

/// A [TwistInstance] wrapped as a [ConnectionChoice]. Used for "chat with"
/// targets like Plot AI. Selection is applied via the parent page's
/// existing `_selectTwist` path (sets `thread.icon = 'twist:N'`); this
/// choice does not produce a `CreateLinkUserAction`.
class TwistConnectionChoice implements ConnectionChoice {
  TwistConnectionChoice(
    this.twist, {
    required this.allInstances,
    this.teamName,
  });

  final TwistInstance twist;
  final List<TwistInstance> allInstances;
  final String? teamName;

  String get _displayThreadType =>
      twist.threadType ?? '${twist.handle.isEmpty ? twist.name : twist.handle} chat';

  String get _scopeSuffix {
    if (twist.multipleInstances) return '';
    final hasSibling = allInstances.any(
      (other) =>
          other.id != twist.id &&
          other.twistId == twist.twistId &&
          other.archivedAt == null,
    );
    if (!hasSibling) return '';
    final scopeLabel = twist.teamId == null ? 'Personal' : (teamName ?? 'Team');
    return ' ($scopeLabel)';
  }

  @override
  String get key => 'twist:${twist.id}';

  @override
  String get label => '$_displayThreadType$_scopeSuffix';

  @override
  String? get logo => twist.logoUrl;

  @override
  String? get logoDark => twist.logoUrlDark;

  @override
  String get searchText =>
      '${_displayThreadType.toLowerCase()} ${(twist.handle.isEmpty ? twist.name : twist.handle).toLowerCase()}';

  @override
  CreateLinkUserAction? toUserAction() => null;
}
```

- [ ] **Step 2: Verify with `flutter analyze`**

```bash
cd apps/plot && flutter analyze lib/widget/compose/connection_choice.dart
```

Expected: zero errors.

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/widget/compose/connection_choice.dart
git commit -m "Add TwistConnectionChoice to ConnectionChoice"
```

---

## Task 7: Render the twist case in `ConnectionComposeField`

**Files:**
- Modify: `apps/plot/lib/widget/compose/connection_compose_field.dart`

- [ ] **Step 1: Handle the twist case in the switch**

In `apps/plot/lib/widget/compose/connection_compose_field.dart`, extend the switch in `build` (around line 36) to include the new case:

```dart
    final Widget logo;
    final String title;
    final String subtitle;
    switch (activeChoice) {
      case PlotThreadChoice():
        logo = SvgPicture.asset(
          'assets/plot-icon.svg',
          width: theme.iconSizes.sm,
          height: theme.iconSizes.sm,
        );
        title = 'Plot thread';
        subtitle = '';
      case TargetConnectionChoice(:final target):
        final url = isDark
            ? (target.linkType.logoDark ?? target.linkType.logo)
            : target.linkType.logo;
        logo = url != null
            ? LogoImage(
                url: url,
                size: theme.iconSizes.sm,
                fallback: const Icon(PlotIcon.link),
              )
            : const Icon(PlotIcon.link);
        title = connectionTargetTitle(target);
        subtitle = connectionTargetSubtitle(target);
      case TwistConnectionChoice(:final twist):
        final url = isDark ? (twist.logoUrlDark ?? twist.logoUrl) : twist.logoUrl;
        logo = url != null
            ? LogoImage(
                url: url,
                size: theme.iconSizes.sm,
                fallback: const Icon(PlotIcon.twist),
              )
            : const Icon(PlotIcon.twist);
        title = (activeChoice as TwistConnectionChoice).label;
        subtitle = '';
    }
```

- [ ] **Step 2: Verify with `flutter analyze`**

```bash
cd apps/plot && flutter analyze lib/widget/compose/connection_compose_field.dart
```

Expected: zero errors.

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/widget/compose/connection_compose_field.dart
git commit -m "Render TwistConnectionChoice in ConnectionComposeField"
```

---

## Task 8: Include twists in `ConnectionPickerModal`

**Files:**
- Modify: `apps/plot/lib/widget/connection_chip.dart`

- [ ] **Step 1: Make the picker accept the available twists**

In `apps/plot/lib/widget/connection_chip.dart`, change the `ConnectionPickerModal.open` signature to take the twist list and team name (so the page can pass them from `PriorityBloc.state`):

```dart
/// Modal listing every create-target, every chat-eligible twist, plus the
/// synthetic "Plot thread" row. Returns the picked ConnectionChoice or
/// null on dismiss.
class ConnectionPickerModal {
  ConnectionPickerModal._();

  static Future<ConnectionChoice?> open(
    BuildContext context, {
    required List<TwistInstance> twists,
    String? teamName,
  }) async {
    final targets = await loadCreateTargets();
    if (!context.mounted) return null;

    // Only twists that opt in via `threadType` appear as chat targets.
    final chatTwists = twists
        .where((t) => !t.isSource && (t.threadType?.isNotEmpty ?? false))
        .toList();

    final choices = <ConnectionChoice>[
      ConnectionChoice.plotThread,
      ...chatTwists.map(
        (t) => ConnectionChoice.twist(
          t,
          allInstances: twists,
          teamName: teamName,
        ),
      ),
      ...targets.map(ConnectionChoice.target),
    ];

    final result = await SelectModal.open<ConnectionChoice>(
      context,
      items: (search) async {
        final text = search?.trim().toLowerCase() ?? '';
        final filtered = text.isEmpty
            ? choices
            : choices.where((c) => c.searchText.contains(text)).toList();
        return [SelectGroup(title: null, items: filtered)];
      },
      itemBuilder: (choice, _) => switch (choice) {
        PlotThreadChoice() => ListTile(
            leadingBuilder: (_, _) => Builder(
              builder: (context) => Padding(
                padding: EdgeInsets.only(
                  left: context.theme.spacing.lg,
                  right: 8,
                ),
                child: SvgPicture.asset(
                  'assets/plot-icon.svg',
                  width: 16,
                  height: 16,
                ),
              ),
            ),
            title: 'Plot thread',
          ),
        TargetConnectionChoice(:final target) =>
          connectionTargetTile(context, target),
        TwistConnectionChoice() => _twistChoiceTile(context, choice),
      },
      prompt: 'Pick a connection',
      emptyMessage: 'No connections available',
      showFilter: true,
    );
    if (!result.present) return null;
    return result.value;
  }
}

ListTile _twistChoiceTile(BuildContext context, TwistConnectionChoice choice) {
  final isDark = context.read<ThemeBloc>().isDarkMode(context);
  final twist = choice.twist;
  final logo = isDark ? (twist.logoUrlDark ?? twist.logoUrl) : twist.logoUrl;
  return ListTile(
    leadingBuilder: logo != null
        ? (_, _) => Builder(
              builder: (context) => Padding(
                padding: EdgeInsets.only(
                  left: context.theme.spacing.lg,
                  right: 8,
                ),
                child: LogoImage(
                  url: logo,
                  size: 16,
                  fallback: const Icon(PlotIcon.twist, size: 16),
                ),
              ),
            )
        : null,
    icon: logo == null ? PlotIcon.twist : null,
    title: choice.label,
  );
}
```

Also add the new imports at the top of the file (next to existing `import 'package:plot/widget/widget.dart';`):

```dart
import 'package:plot/store/store.dart' show TwistInstance;
```

(`TwistConnectionChoice` and `PlotThreadChoice` are exported via `widget.dart`; verify with grep.)

- [ ] **Step 2: Verify with `flutter analyze`**

```bash
cd apps/plot && flutter analyze lib/widget/connection_chip.dart
```

Expected: zero errors. If `TwistConnectionChoice` isn't exported through `widget.dart`, add an explicit import:

```dart
import 'package:plot/widget/compose/connection_choice.dart';
```

- [ ] **Step 3: Commit**

```bash
git add apps/plot/lib/widget/connection_chip.dart
git commit -m "Include twists in ConnectionPickerModal"
```

---

## Task 9: Wire connection ↔ twist selection on `NewThreadPage`

**Files:**
- Modify: `apps/plot/lib/page/new_thread.dart`

- [ ] **Step 1: Pass twists into the picker call**

In `apps/plot/lib/page/new_thread.dart`, update `_openConnectionPicker` (around line 458):

```dart
  Future<void> _openConnectionPicker() async {
    final twists = context.read<PriorityBloc>().state.twists;
    final picked = await ConnectionPickerModal.open(
      context,
      twists: twists,
    );
    if (picked == null || !mounted) return;
    await _applyConnectionChoice(picked);
  }
```

- [ ] **Step 2: Handle the twist case in `_applyConnectionChoice`**

Replace `_applyConnectionChoice` (around line 441) with the three-case version:

```dart
  /// Routes a ConnectionChoice from the modal/dropdown into the draft.
  /// - Plot thread: clear CreateLinkUserAction and clear any selected twist.
  /// - CreateTarget: set CreateLinkUserAction; clear any selected twist.
  /// - Twist: clear CreateLinkUserAction; set the twist (icon + selected state).
  Future<void> _applyConnectionChoice(ConnectionChoice choice) async {
    final bloc = _priorityBloc;
    if (bloc == null) return;
    final note = bloc.state.draftNote;
    final actions = List<UserAction>.from(note.actions ?? const []);
    actions.removeWhere((a) => a is CreateLinkUserAction);

    if (choice is TwistConnectionChoice) {
      // Drop any active CreateLinkUserAction, then apply the twist via the
      // existing _selectTwist path (sets thread.icon = 'twist:N').
      await bloc.updateDraft(
        bloc.state.draft,
        note: note.copyWith(actions: actions),
      );
      if (!mounted) return;
      _selectTwist(choice.twist);
      return;
    }

    // Plot thread / CreateTarget: clear any selected twist.
    if (_selectedTwist != null) {
      setState(() => _selectedTwist = null);
      final draft = bloc.state.draft;
      // Restore default icon when leaving a twist selection.
      final cleared = draft.copyWith(icon: const Value(null));
      await bloc.updateDraftLocal(cleared);
    }

    final action = choice.toUserAction();
    if (action != null) actions.add(action);
    await bloc.updateDraft(
      bloc.state.draft,
      note: note.copyWith(actions: actions),
    );
  }
```

- [ ] **Step 3: Resolve the active choice including twists**

Replace `_resolveActiveConnectionChoice` (around line 464):

```dart
  ConnectionChoice _resolveActiveConnectionChoice(PriorityState state) {
    if (_selectedTwist != null) {
      return ConnectionChoice.twist(
        _selectedTwist!,
        allInstances: state.twists,
      );
    }
    final active = state.draftNote.actions
        ?.whereType<CreateLinkUserAction>()
        .firstOrNull;
    if (active == null) return ConnectionChoice.plotThread;
    for (final target in _allConnectionTargets) {
      if (active.twistInstanceId == target.twist.id.toString() &&
          active.channelId == target.channel?.channelId &&
          active.linkType == target.linkType.type) {
        return ConnectionChoice.target(target);
      }
    }
    return ConnectionChoice.plotThread;
  }
```

- [ ] **Step 4: Verify with `flutter analyze`**

```bash
cd apps/plot && flutter analyze lib/page/new_thread.dart
```

Expected: zero errors.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/page/new_thread.dart
git commit -m "Wire twists into NewThreadPage connection picker"
```

---

## Task 10: Remove the twist button from `NoteEditor`

**Files:**
- Modify: `apps/plot/lib/widget/note_editor.dart`

- [ ] **Step 1: Remove the twist button call site**

In `apps/plot/lib/widget/note_editor.dart`, find `_buildNewThreadBottomBar` (around line 1176) and delete the twist-button block (around lines 1258-1261):

```dart
                // Twist button (when twists are available)
                if (!widget.viewerMode &&
                    context.read<PriorityBloc>().state.twists.isNotEmpty)
                  _buildNewThreadTwistButton(),
```

(Remove all four lines including the conditional.)

- [ ] **Step 2: Delete `_buildNewThreadTwistButton` and `_openNewThreadTwistPicker`**

Delete the two methods (around lines 1422-1473) entirely.

- [ ] **Step 3: Trim the new-thread branch from `_shortcutSelectTwist`**

Replace `_shortcutSelectTwist` (around line 1548) with the note-mode-only version:

```dart
  void _shortcutSelectTwist(BuildContext context) {
    if (_saving) return;
    // New-thread mode no longer exposes a twist picker shortcut — selection
    // moved to the connection field above the editor.
    if (widget.isNewThreadMode) return;
    final threadState = context.read<ThreadBloc>().state;
    final mentionableTwists = threadState.threadTwists
        .where((t) => !t.isSource)
        .toList();
    if (mentionableTwists.isEmpty) return;
    if (mentionableTwists.length == 1) {
      setState(() {
        final id = mentionableTwists.first.id;
        if (_disabledTwists.contains(id)) {
          _disabledTwists.remove(id);
        } else {
          _disabledTwists.add(id);
        }
      });
      return;
    }
    _openTwistToggleModal(context, mentionableTwists);
  }
```

- [ ] **Step 4: Keep `selectedTwist` / `onTwistSelected` props on `NoteEditor`**

Do NOT remove them — `NewThreadPage` still passes them so the editor knows which twist is active (for the hint text and the `additionalMentions` propagation). They just no longer have a UI affordance inside the editor.

- [ ] **Step 5: Verify with `flutter analyze`**

```bash
cd apps/plot && flutter analyze lib/widget/note_editor.dart
```

Expected: zero errors. If lint flags `onTwistSelected` as unused inside the editor, suppress the warning or accept it — the prop is still required by callers.

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/widget/note_editor.dart
git commit -m "Remove twist button from NoteEditor on NewThreadPage"
```

---

## Task 11: Add `onTwistMentioned` callback to `Editor` → `NoteEditor` → `NewThreadPage`

**Files:**
- Modify: `apps/plot/lib/widget/editor.dart`
- Modify: `apps/plot/lib/widget/note_editor.dart`
- Modify: `apps/plot/lib/page/new_thread.dart`

- [ ] **Step 1: Add the prop to `Editor`**

In `apps/plot/lib/widget/editor.dart`, add a `onTwistMentioned` field to the `Editor` constructor (around line 319):

```dart
class Editor extends StatefulWidget {
  const Editor({
    this.hint,
    this.autofocus = false,
    this.onSubmitted,
    this.onChange,
    this.onIsEmptyChanged,
    this.onImagePasted,
    this.onUrlPastedWhenEmpty,
    this.onTwistMentioned,
    this.focusNode,
    this.twists = const [],
    this.actors = const [],
    this.threadContactIds = const <String>{},
    this.shrinkWrap = true,
    this.initialContent,
    super.key,
  });

  // ...existing fields...

  /// Fires when the user completes an @-mention of a twist from the
  /// suggestion popover. The receiver should treat the selection as a
  /// connection-target pick (parallel to how contact mentions add the
  /// person to the thread). The mention text is still inserted in the
  /// body — this is an additive signal.
  final void Function(String twistId)? onTwistMentioned;
```

Then fire it from `_buildEditorMentionPopover.onItemSelected` (around line 1415):

```dart
      onItemSelected: (item) {
        // Record mention usage for MRU sorting
        localPrefs.recordMentionUsage(item.id);

        _mentionDetector.completeMention(actorId: item.id, username: item.name);
        _editorFocusNode.requestFocus();

        if (item.isTwist) {
          widget.onTwistMentioned?.call(item.id);
        }

        // Notify immediately so thread sharing chips update without debounce delay
        notify();
      },
```

- [ ] **Step 2: Plumb the prop through `NoteEditor`**

In `apps/plot/lib/widget/note_editor.dart`, add the field next to `onTwistSelected` (around line 86):

```dart
  /// Called when user selects a twist from the picker modal.
  final ValueChanged<TwistInstance>? onTwistSelected;

  /// Called when the user completes an @-mention of a twist in the editor
  /// body. Parent should treat as a connection-target pick (parallel to
  /// the contact-mention → add-to-thread behavior). The mention text is
  /// still inserted; this is an additive signal.
  final void Function(String twistId)? onTwistMentioned;
```

Add the prop to the constructor (around line 39):

```dart
    this.selectedTwist,
    this.onTwistSelected,
    this.onTwistMentioned,
```

In `_buildEditorArea` where `Editor(...)` is constructed (around line 545), pass it through:

```dart
      final editor = Editor(
        key: _editorKey,
        hint: hint,
        autofocus:
            widget.autofocus ??
            (widget.isNewThreadMode || hasPhysicalKeyboard()),
        focusNode: focusNode,
        twists: twists,
        actors: actors,
        threadContactIds: threadContactIds,
        shrinkWrap: true,
        initialContent: widget.draft.content,
        onTwistMentioned: widget.onTwistMentioned,
        onIsEmptyChanged: (isEmpty) {
          // ...existing body...
        },
        onChange: widget.isNewThreadMode
            ? (value) {
                _saveDraft(value);
              }
            : null,
        onSubmitted: widget.isNewThreadMode
            ? _onNewThreadSubmitted
            : _onNoteSubmitted,
        onImagePasted: (imageBytes) => _handleImagePaste(imageBytes),
        onUrlPastedWhenEmpty: (url) => _handleUrlPasteWhenEmpty(url),
      );
```

- [ ] **Step 3: Hook the callback up in `NewThreadPage`**

In `apps/plot/lib/page/new_thread.dart`, add a handler near `_selectTwist` (around line 598):

```dart
  void _onTwistMentioned(String twistId) {
    final id = TwistInstanceId.fromString(twistId);
    final twist = TwistInstance.fromCache(id);
    if (twist == null) return;
    // Use the same connection-application path the picker uses so the
    // CreateLinkUserAction (if any) is cleared.
    unawaited(
      _applyConnectionChoice(
        ConnectionChoice.twist(
          twist,
          allInstances: context.read<PriorityBloc>().state.twists,
        ),
      ),
    );
  }
```

Pass it into both `NoteEditor(...)` call sites (single-panel around line 829 and multi-panel around line 899) by adding the prop:

```dart
                                        child: NoteEditor(
                                          key: _threadEditorKey,
                                          bodyOnly: true,
                                          draft: state.draftNote,
                                          thread: state.draft,
                                          onDraftChanged: _handleDraftChanged,
                                          flushToBottom: true,
                                          showScheduleActions: false,
                                          hint: state.draft.priority.isPlotApp
                                              ? 'Ask for help or share feedback'
                                              : _editorHint,
                                          additionalMentions: _twistMentions,
                                          onSubmitted: _onChatSubmitted,
                                          submitValidator: _validateDmSubmit,
                                          viewerMode: isViewerMode,
                                          selectedTwist: _selectedTwist,
                                          onTwistSelected: _selectTwist,
                                          onTwistMentioned: _onTwistMentioned,
                                          onNavigateToThread: (thread) {
                                            context.run(
                                              ChangeCurrentThread(thread),
                                            );
                                          },
                                        ),
```

(Same line added to the multi-panel `NoteEditor(...)`.)

- [ ] **Step 4: Verify with `flutter analyze`**

```bash
cd apps/plot && flutter analyze lib/widget/editor.dart lib/widget/note_editor.dart lib/page/new_thread.dart
```

Expected: zero errors.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/widget/editor.dart apps/plot/lib/widget/note_editor.dart apps/plot/lib/page/new_thread.dart
git commit -m "Wire twist @-mention to connection selection on NewThreadPage"
```

---

## Task 12: Switch mention/author display sites from `displayName` to `mentionLabel`

**Files:**
- Modify: `apps/plot/lib/widget/editor.dart`
- Audit pass on other call sites

- [ ] **Step 1: Update the mention popover label**

In `apps/plot/lib/widget/editor.dart`, change `MentionItem.fromTwist` (around line 292):

```dart
  /// Create from a TwistInstance
  factory MentionItem.fromTwist(
    TwistInstance twist, {
    required List<TwistInstance> allInstances,
    String? teamName,
  }) => MentionItem(
    id: twist.id.toString(),
    name: twist.mentionLabel(allInstances: allInstances, teamName: teamName),
    isTwist: true,
  );
```

- [ ] **Step 2: Audit other call sites of `TwistInstance.displayName`**

```bash
grep -rn "\.displayName(" apps/plot/lib --include="*.dart" | grep -i twist
```

Read each match. For sites that render a twist as **an at-mention completion, the author of a note, or a participant chip**, switch to `mentionLabel(...)`. Leave settings/marketplace/picker call sites on `displayName(...)` — those refer to the twist as an installed package, not as an actor.

Likely additional sites (verify by grep + inspection):
- `apps/plot/lib/store/note.dart` — note author rendering when `mentionId.isTwist`
- `apps/plot/lib/widget/avatar.dart` — avatar fallback name when `a.id.isTwist`
- `apps/plot/lib/state/thread_state.dart` — twist participant display

For each, change `twist.displayName(allInstances: ..., teamName: ...)` → `twist.mentionLabel(allInstances: ..., teamName: ...)`.

- [ ] **Step 3: Verify with `flutter analyze`**

```bash
cd apps/plot && flutter analyze
```

Expected: zero errors across the modified files.

- [ ] **Step 4: Commit**

```bash
git add -p apps/plot/lib   # stage only the displayName → mentionLabel edits
git commit -m "Use mentionLabel for twist at-mentions and author display"
```

---

## Task 13: Manual verification with the running app

**Files:** none modified.

- [ ] **Step 1: Launch the app in the agent profile**

Invoke the `run-app` skill (or follow `.agents/skills/run-app/SKILL.md`):

```
Skill: run-app
```

- [ ] **Step 2: Open `NewThreadPage`**

Click "New thread" from the bottom nav. Verify:

- The twist icon button is GONE from the editor's bottom bar.
- The connection field above the editor still shows "Plot thread" by default.

- [ ] **Step 3: Open the connection picker**

Tap the connection field. Verify the picker order:

1. **Plot thread** (default)
2. **Plot AI chat** (the Plot twist — `threadType` set)
3. Any connector targets (Slack channel, Linear team, etc.) the user has

Twists that don't set `threadType` should NOT appear.

- [ ] **Step 4: Select "Plot AI chat"**

Verify:

- Connection field updates to show the Plot logo + "Plot AI chat".
- Editor hint reads "Chat with Plot" (the existing `_editorHint` path uses `_selectedTwist.name`).
- Thread icon changes to `twist:N` (visible in the draft chip if applicable).

- [ ] **Step 5: At-mention the Plot twist**

In the editor, type `@Plot` and select the Plot twist from the popover. Verify:

- `@Plot` text is inserted in the body (parallel to contact mention behavior).
- The connection field switches to "Plot AI chat" automatically.
- A subsequent picker selection of "Plot thread" both clears the connection AND keeps the @mention text in the body (the mention is just inserted text from the body's perspective; clearing the connection doesn't strip it).

- [ ] **Step 6: Switch back to a connector target**

Select a connector target (e.g. a Slack channel) from the picker. Verify:

- Connection field shows the connector logo + label.
- The previously-selected twist is cleared (`thread.icon` returns to default, `_selectedTwist == null`).

- [ ] **Step 7: Submit the thread**

Type a message, hit submit. Verify a new thread is created and routed correctly (Plot AI chat → handled by the Plot twist's `onSearchQuery` / `onOrganizeQuery` intents; Slack target → created as a Slack link; Plot thread → plain Plot thread).

- [ ] **Step 8: Check note author rendering on existing threads**

Open a thread that has a note authored by a twist (or send a chat to Plot AI and reply). Verify the author label uses `handle` (e.g. "Plot") and not the package `displayName`. Today they happen to be the same string for the Plot twist; the difference will show up if `handle` is set differently in a future twist.

- [ ] **Step 9: Run `/finalize`**

Invoke the `finalize` skill to run lint, error-capture audit, doc updates, and the public-submodule PR check.

---

## Notes for the executing engineer

- **Worktree DB port**: every `psql` call in this plan uses `$DATABASE_URL`. Never hardcode `54322`. See `AGENTS.md` "Worktree Development".
- **Public submodule**: Task 3 lands inside `public/` as a separate commit. Task 4 bumps the submodule reference from the main repo. Don't try to make changes to `public/twister/` from outside the submodule directory.
- **Drift `.g.dart` files** are generated. If `flutter pub run build_runner build` fails inside a worktree, ensure submodule init ran (`git submodule update --init --recursive`) and that `pnpm install` completed.
- **No backwards-compat shims**: per project AGENTS, don't add temporary code paths for old clients that haven't picked up `handle`. The Drift migration backfills `handle` on the client; older app versions that don't know the column simply don't see it.
- **YAGNI**: do not add a keyboard shortcut for the new connection picker, do not add a "recent twists" group, do not add per-instance overrides for `threadType`. The spec calls all of these out of scope.
