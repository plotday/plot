# Single-Instance Twists

**Date:** 2026-04-15

## Context

Twists currently always allow multiple instances per user/team scope. This was too permissive as a default — most twists (e.g. Claude, a summarizer) make no sense installed twice in the same scope. The change makes single-instance the default and adds an opt-in flag for twists that genuinely need multiple instances (e.g. a workflow runner where each instance has different config).

No actor ID changes and no data migration are needed. All existing `twist_instance` records remain valid; the `DEFAULT false` on the new DB column automatically treats existing deployed twists as single-instance.

---

## Architecture

### 1. Twister SDK (`public/twister/src/twist.ts`)

Add a static property to the `Twist` base class:

```typescript
static multipleInstances?: boolean; // default undefined/false = single instance
```

Multi-instance twists declare:

```typescript
static multipleInstances = true;
```

This follows the existing pattern of `Connector.isConnector` and `Connector.handleReplies`. The property is read during the deployment introspection pass (`checkPermissions: false` in `workers/api/src/twist/factory.ts`).

A changeset is required at `public/.changeset/<name>.md`:

```markdown
---
"@plotday/twister": minor
---

Added: `static multipleInstances` property on `Twist` — set to `true` to allow multiple instances per scope; default is single-instance
```

---

### 2. Database (`libs/db/schema/50-tables/90-twist.sql`)

Add column to the `twist` table:

```sql
multiple_instances boolean NOT NULL DEFAULT false
```

`DEFAULT false` means all previously-deployed twists are automatically single-instance — no data migration needed. Generate and apply via `pnpm gen-migration -- add_twist_multiple_instances` then `pnpm apply-migrations`, then `pnpm types`.

---

### 3. Deployment Pipeline (`workers/api/src/twist/storage.ts` + `deployment.ts`)

During the `checkPermissions: false` introspection pass in `storeTwistModule()`, read `TwistClass.multipleInstances` (the static property) from the instantiated module. Pass it through to `deployTwist()` and store it in the `twist` table INSERT/UPDATE alongside `is_source`, `shared`, `key_option`, etc.

---

### 4. API Enforcement (`workers/api/src/twist/management.ts`)

**On activation** (draft → active in `add()` / `activateDraft()`):

If `twist.multiple_instances = false`, check for an existing active instance in the same scope before creating:

```sql
SELECT 1 FROM twist_instance ti
JOIN twist t ON t.id = ti.twist_id
WHERE t.twist_admin_id = <same package>
  AND ti.archived_at IS NULL
  AND ti.draft = false
  AND (
    (ti.owner_id = $userId AND ti.team_id IS NULL AND $teamId IS NULL)
    OR
    (ti.team_id = $teamId AND $teamId IS NOT NULL)
  )
```

Return `409 Conflict` with a descriptive message if a duplicate exists. Old clients get this error naturally — no breaking change to the response shape.

**Name enforcement**: For single-instance twists, override any client-provided `name` with `twist.name` (the package name) server-side during activation.

---

### 5. `GET /twists` Response

No query changes needed. Once `multiple_instances` is added to the `twist` table and types are regenerated, it appears in the `twist.*` rows already returned by `getAllTwists()`. The Flutter `Twist` model parses the new field.

The client uses `multiple_instances` + its local `TwistInstances` cache (which includes `team_id`) to compute availability per scope.

---

### 6. Flutter Client (`apps/plot/lib/`)

#### Data models

- `Twist` API model (`api/twist_api.dart`): add `multipleInstances` field parsed from the response
- `TwistInstances` Drift table (`libs/store/`): add `multipleInstances` column

#### Available twists filtering (`ManageTwists` in `command/twist.dart`)

A single-instance twist appears in "available" if **at least one scope** (personal or any of the user's teams) has no active instance. Computed locally from the `TwistInstances` cache. Multi-instance twists always appear in "available."

#### `SetupTwist` flow (`command/twist.dart`)

**Single-instance twists:**

- Hide the name field; draft is created with the twist's package name
- Show a scope select (Personal / team names) filtered to scopes where the twist is not yet active
  - If the user has teams and only one scope is available: show the select as **readonly** (so the user can see where it will be installed, for consistency with the multi-scope case)
  - If multiple scopes are available: editable select
  - If the user has no teams: no scope select (always Personal)

**Multi-instance twists:** current behavior unchanged (name field shown, no scope filtering)

#### `EditTwist` flow (`command/twist.dart`)

For single-instance twists: remove the name field from the edit form.

#### Name display with scope suffix

When a user has the **same single-instance twist active in more than one scope** (e.g. Personal + a team), append a suffix everywhere the name is displayed:

- Personal instance → `"Claude (Personal)"`
- Team instance → `"Claude (Acme)"`

Affected surfaces: `ManageTwists` active list, mention autocomplete (`MentionItem.fromTwist()`), author attribution in the note editor.

A helper on `TwistInstance` computes the display name: check if any other active, non-archived instance shares the same `twist_admin_id` (via `twist_id`); if so, append the scope suffix.

---

## Verification

1. Deploy a test twist without `multipleInstances` → activate in Personal → confirm it disappears from available (for Personal scope)
2. Attempt to activate the same twist in Personal again via API → confirm `409 Conflict`
3. Deploy a twist with `static multipleInstances = true` → confirm multiple instances can be created in the same scope with distinct names
4. Install a single-instance twist in both Personal and a team → confirm display name shows "(Personal)" / "(Team Name)" in manage list, mentions, and author attribution
5. With one team and the twist already in Personal: open SetupTwist for that twist → confirm scope select is shown readonly with the team scope pre-selected
6. Run `pnpm lint` in `workers/api`, `public/twister`, and `apps/plot`
7. Run `pnpm diff-schema-migrations` → no differences after migration is generated and applied
