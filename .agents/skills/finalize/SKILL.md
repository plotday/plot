---
name: finalize
description: Finalize a code change before committing. Runs lint, checks backwards compatibility, verifies error capture, updates docs, and handles public submodule PRs.
---

# Change Finalization

Run this checklist before committing or declaring any code change complete. Do NOT skip steps. Each step must pass before proceeding to the next.

## Checklist

### 1. Lint

Run `pnpm lint` in each changed package, or run `pnpm lint` at the repo root to lint everything. Fix all errors before continuing.

```bash
# Per-package (preferred for speed):
pnpm --filter @plotday/<package> lint

# Or whole repo:
pnpm lint
```

**Schema/migration changes**: if `git status` shows changes under `libs/db/schema/` or `libs/db/migrations/`, you MUST also have a matching change to `libs/db/src/types.ts`. The CI `db:lint` step runs `tsx scripts/gen-types.ts --check` and fails if the committed types are out of sync with the DB. `pnpm apply-migrations` regenerates `types.ts` automatically (skipped only when `$CI=true`), so the normal workflow handles it — but if you edited a migration without running apply, run `pnpm --filter @plotday/db run types` manually and stage the diff. Don't skip this: a stale `types.ts` is the single most common cause of red CI on schema PRs.

### 2. Backwards Compatibility

Review all changed APIs (REST endpoints, database schemas, RPC functions, Twister SDK types) and verify:

- **No removed fields** that existing clients depend on. If a field must be removed, it should be marked deprecated first and removed in a later release.
- **No renamed fields** without aliases or migration path.
- **No changed semantics** of existing fields (e.g. a field that was optional becoming required).
- **New fields are optional** (nullable or have defaults) so old clients that don't send them still work.
- **Database migrations** don't drop columns or tables that active clients reference.

If a breaking change is intentional, flag it to the user explicitly before proceeding.

### 3. Error Capture

Review all new or modified `catch` blocks and error handling paths. Every catch block handling an **unexpected** error must call `captureException`:

- **Flutter**: `Tracker.captureException(error, stackTrace)`
- **TypeScript workers**: `tracker.captureException(error)` (or `postHog.captureException(error, distinctId)` when no tracker is available)

Do NOT capture expected/handled errors (network timeouts, auth failures the user will see, validation errors).

### 4. Documentation

Evaluate whether the change is user-facing:

- **Notable for users** (new feature, UX improvement, bug fix users would notice): Add a fragment via `pnpm updates:new` (one file in `docs/updates.d/`, folded into `docs/updates.md` at release).
- **Major new functionality or capability changes**: Also update `docs/features.md` to reflect the new capabilities.
- **Internal refactors, infra changes, minor fixes users wouldn't notice**: Skip docs.

### 5. Public Submodule Changes

If any files were modified in the `public/` submodule:

- **Twister SDK changes** (`public/twist/src/`): A changeset file MUST be included at `public/.changeset/<descriptive-name>.md` in the proper format (see CLAUDE.md "Changesets" section). Validate with `cd public && pnpm validate-changesets`.
- **Separate PR**: Changes in the `public/` submodule need their own commit and PR in that repo, pushed before or alongside the main repo PR. Remind the user of this.

## When Done

All 5 checks passed. Proceed to commit/PR.
