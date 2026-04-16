# Single-Instance Twists Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make twists single-instance per scope by default, with an opt-in `static multipleInstances = true` flag for twists that need multiple instances per scope.

**Architecture:** Add `multiple_instances boolean` to the `twist` DB table (stored at deploy time from a new static SDK property). Enforce the constraint in `add()` and `activateDraft()` in management.ts. The Flutter client uses the flag (synced via `user.twist` view + returned in `GET /twists`) to filter available twists, adjust setup UI, and append scope suffixes to display names.

**Tech Stack:** PostgreSQL (Atlas migrations), TypeScript (Cloudflare Workers / Kysely / Zod), Dart/Flutter (Drift, Bloc), pnpm monorepo.

---

## File Map

| File | Change |
|------|--------|
| `libs/db/schema/50-tables/90-twist.sql` | Add `multiple_instances` column |
| `libs/db/schema/90-user-schema/32-twist.sql` | Expose `multiple_instances` in `user.twist` view |
| `public/twister/src/twist.ts` | Add `static multipleInstances?: boolean` |
| `public/.changeset/<name>.md` | Required changeset |
| `workers/api/src/twist/factory.ts` | Extract static `multipleInstances` during deployment pass |
| `workers/api/src/twist/storage.ts` | Pass `multipleInstances` through return value |
| `workers/api/src/twist/deployment.ts` | Write `multiple_instances` to DB |
| `workers/api/src/utils/limits.ts` | Add `SingleInstanceError` class |
| `workers/api/src/twist/management.ts` | Enforce single-instance in `add()` + `activateDraft()` |
| `workers/api/src/app/twists.ts` | Handle `SingleInstanceError` with 409 |
| `apps/plot/lib/store/twist_instance.dart` | Add `multipleInstances` Drift column + migration to v307 |
| `apps/plot/lib/store/store.dart` | Bump `schemaVersion` to 307 + add `onUpgrade` step |
| `apps/plot/lib/api/twist_api.dart` | Parse `multipleInstances` in `Twist.fromJson()` |
| `apps/plot/lib/command/twist.dart` | ManageTwists filter + SetupTwist UI + EditTwist UI + display name suffix |

---

## Task 1: Add `multiple_instances` to `twist` table and `user.twist` view

**Files:**
- Modify: `libs/db/schema/50-tables/90-twist.sql`
- Modify: `libs/db/schema/90-user-schema/32-twist.sql`

- [ ] **Step 1: Add column to schema**

In `libs/db/schema/50-tables/90-twist.sql`, add after the `"execution_limit" integer` line (line 28):

```sql
    "multiple_instances" boolean NOT NULL DEFAULT false
```

The full column block should look like:
```sql
    "execution_limit" integer,
    "multiple_instances" boolean NOT NULL DEFAULT false
```

- [ ] **Step 2: Expose in `user.twist` view**

In `libs/db/schema/90-user-schema/32-twist.sql`, add `t.multiple_instances` after the `t.is_source` line (line 19):

```sql
    t.is_source,
    t.multiple_instances,
    t.shared,
```

- [ ] **Step 3: Generate and apply migration**

```bash
cd /Users/kris.braun/code/plot
pnpm gen-migration -- add_twist_multiple_instances
pnpm apply-migrations
```

Expected: migration file created in `libs/db/migrations/`, applied successfully.

- [ ] **Step 4: Regenerate TypeScript types**

```bash
pnpm types
```

Expected: `libs/db/src/types.ts` updated with `multiple_instances: boolean` on the `twist` table type.

- [ ] **Step 5: Verify schema sync**

```bash
pnpm diff-schema-migrations
```

Expected: no output (schema and migrations in sync).

- [ ] **Step 6: Commit**

```bash
git add libs/db/schema/50-tables/90-twist.sql \
        libs/db/schema/90-user-schema/32-twist.sql \
        libs/db/migrations/ \
        libs/db/src/types.ts
git commit -m "feat: add multiple_instances column to twist table"
```

---

## Task 2: Add `static multipleInstances` to Twister SDK

**Files:**
- Modify: `public/twister/src/twist.ts`
- Create: `public/.changeset/twist-multiple-instances.md`

- [ ] **Step 1: Add static property to `Twist` base class**

In `public/twister/src/twist.ts`, add inside the `Twist` class body just before the constructor (around line 36, before `constructor`):

```typescript
  /**
   * When `true`, users may install multiple instances of this twist within
   * the same scope (personal workspace or team). Each instance must have a
   * distinct name.
   *
   * Defaults to `false` (single instance per scope).
   *
   * @example
   * ```typescript
   * class WorkflowTwist extends Twist<WorkflowTwist> {
   *   static multipleInstances = true;
   *   // ...
   * }
   * ```
   */
  static multipleInstances?: boolean;
```

- [ ] **Step 2: Rebuild Twister**

```bash
cd /Users/kris.braun/code/plot/public/twister
pnpm build
```

Expected: build succeeds with no errors.

- [ ] **Step 3: Create changeset**

Create `public/.changeset/twist-multiple-instances.md`:

```markdown
---
"@plotday/twister": minor
---

Added: `static multipleInstances` property on `Twist` — set to `true` to allow multiple instances per scope; default is single-instance
```

- [ ] **Step 4: Validate changeset**

```bash
cd /Users/kris.braun/code/plot/public
pnpm validate-changesets
```

Expected: passes with no errors.

- [ ] **Step 5: Run pnpm install to pick up rebuilt SDK**

```bash
cd /Users/kris.braun/code/plot
pnpm install
```

- [ ] **Step 6: Commit (in public submodule then main repo)**

```bash
cd /Users/kris.braun/code/plot/public
git add twister/src/twist.ts twister/dist/ .changeset/twist-multiple-instances.md
git commit -m "feat: add static multipleInstances property to Twist base class"

cd /Users/kris.braun/code/plot
git add public
git commit -m "feat: update twister submodule with multipleInstances property"
```

---

## Task 3: Read `multipleInstances` during twist deployment

**Files:**
- Modify: `workers/api/src/twist/factory.ts`
- Modify: `workers/api/src/twist/storage.ts`
- Modify: `workers/api/src/twist/deployment.ts`

- [ ] **Step 1: Extract static property in `factory.ts`**

In `workers/api/src/twist/factory.ts`, in the deployment pass block (where `!checkPermissions`, around line 550 after the `defaultMentionMentioned` assignments), add before the `return` statement:

```typescript
      // Read static multipleInstances flag from the twist class
      const multipleInstances = (twist.constructor as { multipleInstances?: boolean }).multipleInstances ?? false;
```

Then add `multipleInstances` to the return object at line 561:

```typescript
    return {
      permissions,
      toolPermissions: toolPermissionsMap,
      providers,
      integrationsMap,
      optionsSchema,
      sourceProvider,
      aiRequired,
      defaultMentionCreated,
      defaultMentionMentioned,
      multipleInstances,    // <-- add this line
      activate: async (
```

**Important:** The `multipleInstances` variable is only set inside the `!checkPermissions` block, so it must be declared before that block with a default value. Add `let multipleInstances = false;` alongside the other `let` declarations around line 420:

```typescript
    let aiRequired = false;
    let defaultMentionCreated = false;
    let defaultMentionMentioned = false;
    let multipleInstances = false;    // <-- add this line
```

- [ ] **Step 2: Pass through in `storage.ts`**

In `workers/api/src/twist/storage.ts`, destructure `multipleInstances` from the factory call (line 30):

```typescript
  const { permissions, toolPermissions, providers, integrationsMap, optionsSchema, sourceProvider, aiRequired, defaultMentionCreated, defaultMentionMentioned, multipleInstances } = await twistFactory({
```

Add it to the return value (lines 59-69):

```typescript
  return {
    version,
    permissions,
    providers,
    integrationsMap,
    optionsSchema,
    sourceProvider,
    aiRequired,
    defaultMentionCreated,
    defaultMentionMentioned,
    multipleInstances,    // <-- add this line
  };
```

- [ ] **Step 3: Store in `deployment.ts`**

In `workers/api/src/twist/deployment.ts`, destructure `multipleInstances` from `storeResult` (around line 142-189, wherever `storeTwistModule` return is destructured):

```typescript
  optionsSchema = storeResult.optionsSchema;
  sourceProvider = storeResult.sourceProvider ?? null;
  const multipleInstances = storeResult.multipleInstances ?? false;
```

Then add `multiple_instances` to both the `updateTable` SET (around line 241) and `insertInto` VALUES (around line 265):

```typescript
    // In the UPDATE branch:
    twist = await db
      .updateTable("twist")
      .set({
        name,
        description,
        version,
        permissions: JSON.stringify(twistPermissions),
        options_schema: optionsSchema ? JSON.stringify(optionsSchema) : null,
        is_source: providers.length > 0 || isNoProviderConnector,
        shared: sourceProvider?.shared ?? false,
        key_option: sourceProvider?.keyOption ?? null,
        logo_url: logoUrl ?? null,
        logo_url_dark: logoUrlDark ?? null,
        multiple_instances: multipleInstances,    // <-- add this line
      })
      ...

    // In the INSERT branch:
    twist = await db
      .insertInto("twist")
      .values({
        twist_admin_id: twistAdminId,
        environment,
        name,
        description,
        version,
        permissions: JSON.stringify(newTwistPermissions),
        options_schema: optionsSchema ? JSON.stringify(optionsSchema) : null,
        is_source: providers.length > 0 || isNoProviderConnector,
        shared: sourceProvider?.shared ?? false,
        key_option: sourceProvider?.keyOption ?? null,
        logo_url: logoUrl ?? null,
        logo_url_dark: logoUrlDark ?? null,
        multiple_instances: multipleInstances,    // <-- add this line
      })
```

- [ ] **Step 4: Lint**

```bash
cd /Users/kris.braun/code/plot
pnpm --filter @plotday/api lint
```

Expected: no errors.

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/twist/factory.ts \
        workers/api/src/twist/storage.ts \
        workers/api/src/twist/deployment.ts
git commit -m "feat: extract and store multipleInstances flag during twist deployment"
```

---

## Task 4: Add `SingleInstanceError` and enforce single-instance constraint

**Files:**
- Modify: `workers/api/src/utils/limits.ts`
- Modify: `workers/api/src/twist/management.ts`

- [ ] **Step 1: Add `SingleInstanceError` class to `limits.ts`**

In `workers/api/src/utils/limits.ts`, add after the `PlanLimitError` class (after line 77):

```typescript
export class SingleInstanceError extends Error {
  constructor(scope: "personal" | "team") {
    super(
      scope === "team"
        ? "This twist is already active for this team."
        : "This twist is already active in your personal workspace."
    );
    this.name = "SingleInstanceError";
  }
}
```

- [ ] **Step 2: Enforce in `add()` in `management.ts`**

In `workers/api/src/twist/management.ts`:

First, import `SingleInstanceError`:
```typescript
import { BUILTIN_TWIST_PACKAGE_ID, checkTwistLimit, SingleInstanceError } from "../utils/limits";
```

In `add()`, change the existing twist record fetch (around line 154) to also select `multiple_instances` and `twist_admin_id`:

```typescript
    const twistRecord = await db
      .selectFrom("twist")
      .select(["permissions", "is_source", "multiple_instances", "twist_admin_id"])
      .where("id", "=", String(twist_id))
      .executeTakeFirst();
```

After the plan limit check (after line 195), add the single-instance scope check and name override:

```typescript
    // Single-instance enforcement and name handling
    if (twistRecord?.multiple_instances === false && twistRecord?.is_source !== true) {
      // For single-instance twists, always use the package name
      name = twistName;

      // Check for existing active instance in the same scope (same package, same scope)
      const existingInstance = await db
        .selectFrom("twist_instance")
        .innerJoin("twist as t2", "t2.id", "twist_instance.twist_id")
        .select("twist_instance.id")
        .where("t2.twist_admin_id", "=", twistRecord.twist_admin_id)
        .where("twist_instance.archived_at", "is", null)
        .where("twist_instance.draft", "=", false)
        .$if(team_id != null, (qb) => qb.where("twist_instance.team_id", "=", team_id!))
        .$if(team_id == null, (qb) =>
          qb.where("twist_instance.owner_id", "=", userId).where("twist_instance.team_id", "is", null)
        )
        .executeTakeFirst();

      if (existingInstance) {
        throw new SingleInstanceError(team_id ? "team" : "personal");
      }
    }
```

Also, skip the name-uniqueness check for single-instance twists. In the existing name uniqueness block (around line 200), wrap it to only apply when `multiple_instances !== false`:

```typescript
    // Name uniqueness check — only for multi-instance twists
    // Single-instance twists always use the package name (enforced above) and need no uniqueness check
    if (twistRecord?.is_source !== true && twistRecord?.multiple_instances !== false) {
      const existingTwist = await db
        .selectFrom("twist_instance")
        ...
```

- [ ] **Step 3: Enforce in `activateDraft()` in `management.ts`**

In `activateDraft()`, change the existing twist record fetch (around line 803) to also select `multiple_instances` and `twist_admin_id`:

```typescript
  const twistRecord = await db
    .selectFrom("twist")
    .select(["permissions", "is_source", "multiple_instances", "twist_admin_id", "name"])
    .where("id", "=", String(draft.twist_id))
    .executeTakeFirst();
```

After the plan limit check (around line 844), add:

```typescript
  // Single-instance enforcement and name override
  if (twistRecord?.multiple_instances === false && twistRecord?.is_source !== true) {
    // Always use package name for single-instance twists
    name = twistRecord.name;

    // Check for existing active instance in the same scope (excluding the draft itself)
    const existingInstance = await db
      .selectFrom("twist_instance")
      .innerJoin("twist as t2", "t2.id", "twist_instance.twist_id")
      .select("twist_instance.id")
      .where("t2.twist_admin_id", "=", twistRecord.twist_admin_id)
      .where("twist_instance.id", "!=", draftId)  // exclude the draft itself
      .where("twist_instance.archived_at", "is", null)
      .where("twist_instance.draft", "=", false)
      .$if(teamId != null, (qb) => qb.where("twist_instance.team_id", "=", teamId!))
      .$if(teamId == null, (qb) =>
        qb.where("twist_instance.owner_id", "=", draft.owner_id).where("twist_instance.team_id", "is", null)
      )
      .executeTakeFirst();

    if (existingInstance) {
      throw new SingleInstanceError(teamId ? "team" : "personal");
    }
  }
```

Also wrap the name-uniqueness check in `activateDraft()` (around line 847) to skip for single-instance twists:

```typescript
  // Name uniqueness — only for multi-instance twists
  if (twistRecord?.is_source !== true && twistRecord?.multiple_instances !== false) {
    const existingTwist = await db
      .selectFrom("twist_instance")
      ...
```

- [ ] **Step 4: Lint**

```bash
pnpm --filter @plotday/api lint
```

Expected: no errors.

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/utils/limits.ts \
        workers/api/src/twist/management.ts
git commit -m "feat: enforce single-instance constraint in twist add and activate"
```

---

## Task 5: Handle `SingleInstanceError` with 409 in route handlers

**Files:**
- Modify: `workers/api/src/app/twists.ts`

- [ ] **Step 1: Import `SingleInstanceError`**

In `workers/api/src/app/twists.ts`, update the limits import:

```typescript
import { PlanLimitError, SingleInstanceError } from "../utils/limits";
```

- [ ] **Step 2: Handle in `POST /twist` handler**

In the `POST /twist` catch block (around line 292), add before the generic `Error` check:

```typescript
    if (error instanceof PlanLimitError) {
      return c.json(error.toJSON(), 403);
    }
    if (error instanceof SingleInstanceError) {
      return c.json({ message: error.message, code: "single_instance_conflict" }, 409);
    }
    if (error instanceof Error) {
      return c.json({ message: `Error adding twist: ${error.message}` }, 400);
    }
```

- [ ] **Step 3: Handle in `POST /twist/draft/:id/activate` handler**

Find the activate catch block (around line 370+) and add the same handler:

```typescript
    if (error instanceof PlanLimitError) {
      return c.json(error.toJSON(), 403);
    }
    if (error instanceof SingleInstanceError) {
      return c.json({ message: error.message, code: "single_instance_conflict" }, 409);
    }
    if (error instanceof Error) {
      return c.json({ message: `Error activating twist: ${error.message}` }, 400);
    }
```

- [ ] **Step 4: Lint**

```bash
pnpm --filter @plotday/api lint
```

Expected: no errors.

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/app/twists.ts
git commit -m "feat: return 409 for single-instance conflict in twist routes"
```

---

## Task 6: Flutter Drift store — add `multipleInstances` column

**Files:**
- Modify: `apps/plot/lib/store/twist_instance.dart`
- Modify: `apps/plot/lib/store/store.dart`

- [ ] **Step 1: Add column to `TwistInstances` table**

In `apps/plot/lib/store/twist_instance.dart`, add `multipleInstances` column after `isBuiltin` (line 24):

```dart
  BoolColumn get multipleInstances => boolean().withDefault(const Constant(false))();
```

- [ ] **Step 2: Update `TwistInstance` constructor**

In the `TwistInstance` constructor (around line 195), add `multipleInstances`:

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
        config: row.config,
        linkTypes: row.linkTypes,
        logoUrl: row.logoUrl,
        logoUrlDark: row.logoUrlDark,
        defaultMentionCreated: row.defaultMentionCreated,
        defaultMentionMentioned: row.defaultMentionMentioned,
        userConnected: row.userConnected,
        isBuiltin: row.isBuiltin,
        multipleInstances: row.multipleInstances,    // <-- add this line
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        archivedAt: row.archivedAt,
        pending: row.pending,
      );
```

- [ ] **Step 3: Bump schema version in `store.dart`**

In `apps/plot/lib/store/store.dart`, change `schemaVersion` from 306 to 307:

```dart
  int get schemaVersion => 307;
```

- [ ] **Step 4: Add migration step**

In `store.dart`, in the `onUpgrade` callback, add before the closing of the existing migration block:

```dart
        if (from < 307) {
          await m.addColumn(twistInstances, twistInstances.multipleInstances);
        }
```

- [ ] **Step 5: Regenerate Drift code**

```bash
cd /Users/kris.braun/code/plot/apps/plot
flutter pub run build_runner build --delete-conflicting-outputs
```

Expected: generated files updated with no errors.

- [ ] **Step 6: Analyze**

```bash
flutter analyze
```

Expected: no errors.

- [ ] **Step 7: Commit**

```bash
git add apps/plot/lib/store/twist_instance.dart \
        apps/plot/lib/store/store.dart \
        apps/plot/lib/store/store.g.dart
git commit -m "feat: add multipleInstances column to TwistInstances Drift store"
```

---

## Task 7: Flutter `Twist` API model — parse `multipleInstances`

**Files:**
- Modify: `apps/plot/lib/api/twist_api.dart`

- [ ] **Step 1: Add field to `Twist` class**

In `apps/plot/lib/api/twist_api.dart`, add `multipleInstances` to the `Twist` class fields (after `aiRequired`, around line 42):

```dart
  final bool multipleInstances;
```

- [ ] **Step 2: Add to constructor**

In the `Twist` const constructor (around line 45):

```dart
    this.multipleInstances = false,
```

- [ ] **Step 3: Parse in `Twist.fromJson()`**

In `Twist.fromJson()`, add to the return statement (around line 113):

```dart
      multipleInstances: json['multiple_instances'] as bool? ?? false,
```

- [ ] **Step 4: Analyze**

```bash
cd /Users/kris.braun/code/plot/apps/plot
flutter analyze
```

Expected: no errors.

- [ ] **Step 5: Commit**

```bash
git add apps/plot/lib/api/twist_api.dart
git commit -m "feat: parse multipleInstances field in Twist API model"
```

---

## Task 8: Flutter `ManageTwists` — filter available single-instance twists

**Files:**
- Modify: `apps/plot/lib/command/twist.dart`

- [ ] **Step 1: Add `_isFullyInstalled` helper**

In `apps/plot/lib/command/twist.dart`, add a private file-level function before the `ManageTwists` class (around line 1584):

```dart
/// Returns true if [twist] is a single-instance twist that is already active
/// in every scope available to the user (personal + all teams), making it
/// unavailable for additional installation.
bool _isFullyInstalled(
  Twist twist,
  List<TwistInstance> instances,
  List<TeamInfo> teams,
) {
  if (twist.multipleInstances) return false;

  // Check personal scope
  final inPersonal = instances.any(
    (i) =>
        i.twistId.toString() == twist.id &&
        i.teamId == null &&
        i.archivedAt == null,
  );
  if (!inPersonal) return false;

  // Check all team scopes
  for (final team in teams) {
    final inTeam = instances.any(
      (i) =>
          i.twistId.toString() == twist.id &&
          i.teamId?.toString() == team.id &&
          i.archivedAt == null,
    );
    if (!inTeam) return false;
  }

  return true;
}
```

- [ ] **Step 2: Apply filter in `_getTwistCommands`**

In `ManageTwists._getTwistCommands` (around line 1656), replace:

```dart
    final addCommands = twistOnlyAvailable
        .map((twist) => ShowTwistInfo(twist))
        .toList();
```

With:

```dart
    final teams = usage?.teams ?? [];
    final addCommands = twistOnlyAvailable
        .where((twist) => !_isFullyInstalled(twist, twistOnlyTwistInstances, teams))
        .map((twist) => ShowTwistInfo(twist))
        .toList();
```

- [ ] **Step 3: Analyze**

```bash
flutter analyze
```

Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/command/twist.dart
git commit -m "feat: filter fully-installed single-instance twists from available list"
```

---

## Task 9: Flutter `SetupTwist` — hide name, scope-aware select

**Files:**
- Modify: `apps/plot/lib/command/twist.dart`

- [ ] **Step 1: Add `_getAvailableScopes` helper**

After the `_isFullyInstalled` helper added in Task 8, add:

```dart
/// Returns the list of scope IDs where [twist] can still be installed.
/// For multi-instance twists, returns all scopes (personal + all teams).
/// For single-instance twists, returns only scopes without an active instance.
List<String> _getAvailableScopes(
  Twist twist,
  List<TwistInstance> instances,
  List<TeamInfo> teams,
) {
  if (twist.multipleInstances) {
    return ['personal', ...teams.map((t) => t.id)];
  }

  final scopes = <String>[];

  final inPersonal = instances.any(
    (i) =>
        i.twistId.toString() == twist.id &&
        i.teamId == null &&
        i.archivedAt == null,
  );
  if (!inPersonal) scopes.add('personal');

  for (final team in teams) {
    final inTeam = instances.any(
      (i) =>
          i.twistId.toString() == twist.id &&
          i.teamId?.toString() == team.id &&
          i.archivedAt == null,
    );
    if (!inTeam) scopes.add(team.id);
  }

  return scopes;
}
```

- [ ] **Step 2: Fetch installed instances in `_buildForm`**

In `SetupTwist._buildForm` (around line 2090), update `Future.wait` to also fetch installed twist instances:

```dart
    final results = await Future.wait([
      TwistApi.getIntegrations(draftId),
      ManageConnections._dataCache?.usage != null
          ? Future.value(ManageConnections._dataCache!.usage!)
          : UpgradeApi.getUsage(),
      TwistInstance.get(),    // <-- add this line
    ]);
    final integrations = results[0] as TwistIntegrations;
    final usage = results[1] as UsageData;
    final twistInstances = results[2] as List<TwistInstance>;    // <-- add this line
    final teams = usage.teams;
```

- [ ] **Step 3: Compute available scopes**

After fetching `teams`, add:

```dart
    final availableScopes = _getAvailableScopes(twist, twistInstances, teams);
```

- [ ] **Step 4: Replace name field and team select**

Replace the existing `FormTextInput(key: 'name', ...)` and `FormSelect(key: 'team_id', ...)` block (lines 2143-2162) with:

```dart
            // Name field — hidden for single-instance twists
            if (twist.multipleInstances)
              FormTextInput(
                key: 'name',
                label: 'Name',
                initialValue: twist.name,
                required: true,
              ),

            // Scope select — shown only when user has teams
            if (teams.isNotEmpty)
              FormSelect<String>(
                key: 'team_id',
                label: 'Scope',
                initialValue: availableScopes.isNotEmpty ? availableScopes.first : 'personal',
                items: (search) async => availableScopes,
                titleBuilder:
                    (id) =>
                        id == 'personal'
                            ? 'Personal'
                            : teams.firstWhere((t) => t.id == id).name,
                // For single-instance twists with only one available scope,
                // show readonly so the user can see where it will be installed
                readonlyMessage:
                    !twist.multipleInstances && availableScopes.length == 1
                        ? 'Already active in all other scopes'
                        : null,
              ),
```

- [ ] **Step 5: Ensure name is set correctly when submitting**

Find the form submission handler in `command/twist.dart` — search for `TwistApi.activateDraft` or `ActivateDraftCommand`. The `name` passed to `activateDraft` should use the package name for single-instance twists:

```dart
    final name = twist.multipleInstances
        ? (values['name'] as String? ?? twist.name)
        : twist.name;
```

Pass this `name` to `TwistApi.activateDraft(draftId, name: name, ...)`.

(The API also enforces the name override server-side, so this is a belt-and-suspenders fix for UI consistency.)

- [ ] **Step 6: Analyze**

```bash
flutter analyze
```

Expected: no errors.

- [ ] **Step 7: Commit**

```bash
git add apps/plot/lib/command/twist.dart
git commit -m "feat: hide name field and add scope select for single-instance twist setup"
```

---

## Task 10: Flutter `EditTwist` — hide name field for single-instance twists

**Files:**
- Modify: `apps/plot/lib/command/twist.dart`

- [ ] **Step 1: Update `EditTwist._buildForm`**

In `EditTwist._buildForm` (around line 1728), fetch the matching twist to get its `multipleInstances` flag. The existing code already fetches `allTwists` and finds `matchingTwist` (line 1728):

```dart
      final matchingTwist = allTwists.firstWhere(
        (a) => a.id == twistInstance.twistId.toString(),
        orElse: () => throw Exception('Twist not found'),
      );
```

- [ ] **Step 2: Wrap name field with conditional**

Replace the unconditional `FormTextInput(key: 'name', ...)` (around line 1767) with:

```dart
              // Name is hidden and not editable for single-instance twists
              if (matchingTwist.multipleInstances)
                FormTextInput(
                  key: 'name',
                  label: 'Name',
                  initialValue: twistInstance.name,
                  required: true,
                ),
```

- [ ] **Step 3: Analyze**

```bash
flutter analyze
```

Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add apps/plot/lib/command/twist.dart
git commit -m "feat: hide name field in EditTwist for single-instance twists"
```

---

## Task 11: Flutter — display name scope suffix

**Files:**
- Modify: `apps/plot/lib/store/twist_instance.dart`
- Modify: `apps/plot/lib/command/twist.dart`

- [ ] **Step 1: Add `displayName` helper to `TwistInstance`**

In `apps/plot/lib/store/twist_instance.dart`, add a method to `TwistInstance` (after `parsedLinkTypes`, around line 232):

```dart
  /// Returns the display name for this twist instance.
  ///
  /// For single-instance twists, if the user has the same twist (same [twistId])
  /// installed in multiple scopes (e.g. Personal + a team), appends a scope
  /// suffix so the user can distinguish them:
  ///   - Personal scope → "Claude (Personal)"
  ///   - Team scope     → "Claude (Acme)"
  ///
  /// [allInstances] should be all active, non-archived TwistInstance rows for
  /// the current user. [teamName] is the display name of the team that owns
  /// this instance (null for personal).
  String displayName({
    required List<TwistInstance> allInstances,
    String? teamName,
  }) {
    // Multi-instance twists always use their configured name as-is
    if (multipleInstances) return name;

    // Check if any sibling instance shares the same twist package
    // (same twistId = same twist.id = same package in this environment)
    final hasSibling = allInstances.any(
      (other) =>
          other.id != id &&
          other.twistId == twistId &&
          other.archivedAt == null,
    );

    if (!hasSibling) return name;

    final scopeLabel = teamId == null ? 'Personal' : (teamName ?? 'Team');
    return '$name ($scopeLabel)';
  }
```

- [ ] **Step 2: Update `ManageTwists` active list to use `displayName`**

In `ManageTwists._getTwistCommands`, when building `editCommands`, pass the team name. Since `usage.teams` is already fetched, find the team name:

```dart
    final editCommands = twistOnlyTwistInstances.map((twist) {
      final teamName = twist.teamId != null
          ? teams.firstWhereOrNull((t) => t.id == twist.teamId.toString())?.name
          : null;
      return EditTwist(
        twist,
        displayName: twist.displayName(
          allInstances: twistOnlyTwistInstances,
          teamName: teamName,
        ),
      );
    }).toList();
```

Update `EditTwist` to accept an optional `displayName` parameter:

```dart
class EditTwist extends ShowForm {
  EditTwist(this.twistInstance, {String? displayName})
    : super(
        title: displayName ?? twistInstance.name,
        icon: PlotIcon.settings,
        form: (context) => _buildForm(context, twistInstance),
      );
```

- [ ] **Step 3: Update `MentionItem.fromTwist` to use `displayName`**

Find `MentionItem.fromTwist` in `apps/plot/lib/` (search for it):

```bash
grep -rn "MentionItem.fromTwist\|fromTwist" /Users/kris.braun/code/plot/apps/plot/lib/ | head -10
```

Update the `fromTwist` factory to accept all instances and a team name, computing the display name:

```dart
factory MentionItem.fromTwist(
  TwistInstance twist, {
  required List<TwistInstance> allInstances,
  String? teamName,
}) =>
    MentionItem(
      id: twist.id.toString(),
      name: twist.displayName(allInstances: allInstances, teamName: teamName),
      isTwist: true,
    );
```

Update all call sites of `MentionItem.fromTwist` to pass `allInstances` and `teamName`. Find call sites:

```bash
grep -rn "MentionItem.fromTwist" /Users/kris.braun/code/plot/apps/plot/lib/
```

Each call site must be updated to pass `allInstances` (use `TwistInstance._cache.values.toList()` for synchronous call sites) and `teamName` (resolve from the twist instance's `teamId` against the user's teams list).

- [ ] **Step 4: Update author attribution in note editor**

Search for where twist instance names are displayed as author names in `apps/plot/lib/widget/note_editor.dart` and related files:

```bash
grep -rn "twist\.name\|twistInstance\.name" /Users/kris.braun/code/plot/apps/plot/lib/widget/note_editor.dart
```

For any location that shows a twist's name as a thread/note author, replace `.name` with `.displayName(allInstances: TwistInstance._cache.values.toList(), teamName: ...)`. The team name can be resolved via the cached teams list (from `UsageData`) keyed by `teamId`.

- [ ] **Step 5: Analyze**

```bash
flutter analyze
```

Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add apps/plot/lib/store/twist_instance.dart \
        apps/plot/lib/command/twist.dart \
        apps/plot/lib/widget/note_editor.dart
git commit -m "feat: append scope suffix to single-instance twist display names"
```

---

## Verification

- [ ] Start the local API worker: `pnpm --filter @plotday/api dev`
- [ ] Deploy a test twist (without `static multipleInstances = true`) to personal environment
- [ ] Activate it in Personal scope → confirm it disappears from "Available twists" in the app (no teams case)
- [ ] Attempt to activate the same twist again via `POST /twist` API → confirm `409` with `code: "single_instance_conflict"`
- [ ] Deploy a twist with `static multipleInstances = true` → confirm multiple instances can be created in the same scope with distinct names
- [ ] Install the same single-instance twist in both Personal and a team → confirm display name shows "(Personal)" / "(Team Name)" in the manage list
- [ ] Open SetupTwist for a twist already installed in Personal (user has one team, team scope still available) → confirm scope select shows "Team Name" readonly with `readonlyMessage` toast on tap
- [ ] Confirm the name field is absent in SetupTwist and EditTwist for a single-instance twist, and present for a multi-instance twist
- [ ] Run `pnpm lint` in `workers/api` and `public/twister`
- [ ] Run `flutter analyze` in `apps/plot`
- [ ] Run `pnpm diff-schema-migrations` → no output
