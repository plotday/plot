# Git-Driven Connector Publishing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make "which connectors are public" a git-tracked manifest in the private repo, deploy private connectors through CI, and authorize public deploys in prod via a `publisher.can_publish_public` grant (replacing the dev-only `@plot.day` shortcut).

**Architecture:** A manifest file `connectors/deploy.json` lists public connector package names (default: everything else → `review`). CI (`deploy-twists.yml`) discovers connectors from both `connectors/*` and `public/connectors/*`, and deploys each to `public` or `review` based on the manifest. The API gates `-e public` on the resolving publisher's new `can_publish_public` column, returning a clear `403` otherwise. Promotion touches no DB state beyond the deploy's own twist-row upsert plus normal token auth.

**Tech Stack:** TypeScript (Cloudflare Workers / Hono), Kysely + Postgres, Atlas migrations, GitHub Actions (bash/jq), vitest, Twister CLI (`public/` submodule).

**Reference spec:** `docs/superpowers/specs/2026-06-10-git-driven-connector-publishing-design.md`

---

## Background facts (verified during design)

- End users only see twist rows with `environment = 'public'` (`workers/api/src/app/account.ts:112,557`, `invitation.ts:479`).
- The deploy route is `POST /v1/twist/:id` in `workers/api/src/sdk/twist.ts:326`. The body Zod enum already accepts `"public"` (`sdk/twist.ts:84-87`); the CLI passes `-e` through verbatim.
- The dev-only public block to DELETE is `sdk/twist.ts:396-419`.
- `resolvedPublisherId: number | null` is computed by the existing user-token / publisher-token branches at `sdk/twist.ts:438-483`; it stays `null` for `personal`.
- The Plot publisher is keyed by `lower(name) = 'plot'` (seed `libs/db/schema/99-data/20-plot-system.sql:26-31`).
- `publisher` table: `libs/db/schema/50-tables/20-publisher.sql`.
- DB integration tests use a real local Postgres via `$DATABASE_URL` with a `Rollback` sentinel and `SET LOCAL session_replication_role = replica` to disable FK triggers — pattern in `workers/api/src/twist/deployment.test.ts:1-70`.
- Current prod **public connectors** (preserve these in the manifest, plus add LinkedIn): Airtable, Attio, GitHub, Gmail, Google Calendar, Google Chat, Google Contacts, Google Drive, Google Tasks, Granola, Linear, Outlook Calendar, Slack. (ChatGPT/Claude/Gemini/Plot are twists, not connectors — excluded.)

> ⚠️ **Behavior-preserving requirement:** Because non-listed connectors deploy to `review`, the manifest must capture the **exact** current public set or a live connector silently stops receiving updates (its stale `public` row persists — demotion is not implemented). Task 4 includes a cross-check.

---

## Task 1: Add `publisher.can_publish_public` column + grant Plot

**Files:**
- Modify: `libs/db/schema/50-tables/20-publisher.sql`
- Modify: `libs/db/schema/99-data/20-plot-system.sql`
- Create (generated): `libs/db/migrations/<timestamp>_add_publisher_can_publish_public.sql`
- Modify (generated): `libs/db/src/types.ts`, `libs/db/migrations/atlas.sum`
- Test: `workers/api/src/twist/public-deploy-auth.test.ts` (added in Task 2; the Plot-grant read-back assertion lives there)

- [ ] **Step 1: Add the column to the schema**

In `libs/db/schema/50-tables/20-publisher.sql`, add the column after `"url" text` (keep the trailing comma correct):

```sql
CREATE TABLE "public"."publisher" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "created_by" uuid NOT NULL REFERENCES public."user" ("id") ON DELETE RESTRICT,
    "name" text NOT NULL,
    "email" text,
    "url" text,
    -- When true, deploys from this publisher may target the 'public'
    -- environment (end-user-visible). Granted to Plot's own publisher; all
    -- others default false and must request access. Enforced in the deploy
    -- route (workers/api/src/sdk/twist.ts).
    "can_publish_public" boolean NOT NULL DEFAULT false
);
```

- [ ] **Step 2: Set the flag in the dev seed**

In `libs/db/schema/99-data/20-plot-system.sql`, inside the `DO $$ ... BEGIN ... END $$;` block, right after the line `SELECT id INTO v_publisher_id FROM "public"."publisher" WHERE lower(name) = 'plot' LIMIT 1;` (currently line 31), add an idempotent grant (the publisher INSERT uses `ON CONFLICT DO NOTHING`, so it won't update an existing row — this UPDATE covers re-runs):

```sql
    -- Grant Plot's publisher the right to deploy connectors to 'public'.
    UPDATE "public"."publisher" SET can_publish_public = true
    WHERE id = v_publisher_id AND can_publish_public = false;
```

- [ ] **Step 3: Verify $DATABASE_URL targets the local DB**

Run: `psql "$DATABASE_URL" -tAc "show port;"`
Expected: `54322` in the main repo (or the worktree port from `.worktree-db` — must NOT be a remote host). If this errors, the local DB isn't up: `pnpm --filter @plotday/db start`.

- [ ] **Step 4: Generate the migration**

Run: `pnpm gen-migration -- add_publisher_can_publish_public`
Expected: a new file `libs/db/migrations/<timestamp>_add_publisher_can_publish_public.sql` containing `ALTER TABLE "publisher" ADD COLUMN "can_publish_public" boolean NOT NULL DEFAULT false;` (data UPDATEs are not auto-generated — added next).

- [ ] **Step 5: Append the prod/data backfill to the generated migration**

Open the generated migration file and append at the end (this grants the flag on already-seeded dev DBs and in prod, where the publisher row already exists):

```sql
-- Grant Plot's publisher the right to deploy to the public environment.
UPDATE "public"."publisher" SET can_publish_public = true
WHERE lower(name) = 'plot';
```

Then re-hash so CI's checksum check passes:

Run: `atlas migrate hash --dir file://libs/db/migrations`

- [ ] **Step 6: Apply the migration and regenerate types**

Run: `pnpm apply-migrations`
Expected: migration applies cleanly; `libs/db/src/types.ts` is regenerated (auto-runs `pnpm types`) and now has `can_publish_public: boolean` (well, `Generated<boolean>` / `boolean`) on the `Publisher` table.

- [ ] **Step 7: Verify schema/migrations in sync and the grant landed**

Run: `pnpm diff-schema-migrations`
Expected: no differences.

Run: `psql "$DATABASE_URL" -tAc "SELECT can_publish_public FROM publisher WHERE lower(name)='plot';"`
Expected: `t`

- [ ] **Step 8: Commit**

```bash
git add libs/db/schema/50-tables/20-publisher.sql libs/db/schema/99-data/20-plot-system.sql libs/db/migrations/ libs/db/src/types.ts
git commit -m "feat(db): add publisher.can_publish_public grant"
```

---

## Task 2: Public-deploy authorization helper (TDD)

**Files:**
- Create: `workers/api/src/twist/public-deploy-auth.ts`
- Test: `workers/api/src/twist/public-deploy-auth.test.ts`

The helper loads the resolving publisher and decides whether a `public` deploy is allowed, returning a clear message on denial. Keeping it as a standalone async function makes it unit-testable against the real DB (the route stays thin).

- [ ] **Step 1: Write the failing test**

Create `workers/api/src/twist/public-deploy-auth.test.ts`:

```ts
import { randomUUID } from "node:crypto";

import { sql, type Kysely } from "kysely";
import { describe, expect, it } from "vitest";

import { createDb, type DB } from "../db";
import type { Bindings } from "../env";
import { checkPublicDeployAllowed } from "./public-deploy-auth";

const DATABASE_URL = process.env.DATABASE_URL;
const describeDb = DATABASE_URL ? describe : describe.skip;

class Rollback extends Error {}

/** Insert a publisher with the given flag, run the check, roll back. */
async function withPublisher<T>(
  canPublishPublic: boolean,
  run: (trx: Kysely<DB>, publisherId: number) => Promise<T>,
): Promise<T> {
  const db = createDb({ DATABASE_URL } as unknown as Bindings);
  let result!: T;
  try {
    await db.transaction().execute(async (trx: Kysely<DB>) => {
      await sql`SET LOCAL session_replication_role = replica`.execute(trx);
      const row = await trx
        .insertInto("publisher")
        .values({
          // FK triggers are disabled, so a bare uuid for created_by is fine.
          created_by: randomUUID(),
          name: `Test Publisher ${randomUUID()}`,
          can_publish_public: canPublishPublic,
        })
        .returning(["id"])
        .executeTakeFirstOrThrow();
      result = await run(trx, Number(row.id));
      throw new Rollback();
    });
  } catch (e) {
    if (!(e instanceof Rollback)) throw e;
  } finally {
    await db.destroy();
  }
  return result;
}

describeDb("checkPublicDeployAllowed", () => {
  it("allows public deploy when the publisher is granted", async () => {
    const res = await withPublisher(true, (trx, id) =>
      checkPublicDeployAllowed(trx, "public", id),
    );
    expect(res).toEqual({ ok: true });
  });

  it("denies public deploy with a clear, publisher-named message when not granted", async () => {
    const res = await withPublisher(false, (trx, id) =>
      checkPublicDeployAllowed(trx, "public", id),
    );
    expect(res.ok).toBe(false);
    if (res.ok) throw new Error("expected denial");
    expect(res.message).toContain("not approved to publish to the public environment");
    expect(res.message).toContain("Test Publisher");
  });

  it("allows non-public environments without checking the publisher", async () => {
    const db = createDb({ DATABASE_URL } as unknown as Bindings);
    try {
      expect(await checkPublicDeployAllowed(db, "review", null)).toEqual({ ok: true });
      expect(await checkPublicDeployAllowed(db, "personal", null)).toEqual({ ok: true });
    } finally {
      await db.destroy();
    }
  });

  it("denies a public deploy with no resolved publisher", async () => {
    const db = createDb({ DATABASE_URL } as unknown as Bindings);
    try {
      const res = await checkPublicDeployAllowed(db, "public", null);
      expect(res.ok).toBe(false);
    } finally {
      await db.destroy();
    }
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pnpm --filter @plotday/api exec vitest run src/twist/public-deploy-auth.test.ts`
Expected: FAIL — cannot find module `./public-deploy-auth` (helper not created yet).

- [ ] **Step 3: Implement the helper**

Create `workers/api/src/twist/public-deploy-auth.ts`:

```ts
import { type Kysely } from "kysely";

import { type DB } from "../db";

export type PublicDeployCheck =
  | { ok: true }
  | { ok: false; message: string };

/**
 * Authorize a deploy targeting the `public` environment.
 *
 * Only publishers with `can_publish_public = true` may publish end-user-visible
 * connectors. Non-public environments are always allowed here (other auth is
 * handled in the route). Returns a clear, publisher-named message on denial so
 * the CLI surfaces something actionable.
 */
export async function checkPublicDeployAllowed(
  db: Kysely<DB>,
  environment: string,
  resolvedPublisherId: number | null,
): Promise<PublicDeployCheck> {
  if (environment !== "public") return { ok: true };

  if (resolvedPublisherId === null) {
    return {
      ok: false,
      message:
        "Forbidden: a publisher is required to deploy to the public environment.",
    };
  }

  const publisher = await db
    .selectFrom("publisher")
    .select(["name", "can_publish_public"])
    .where("id", "=", resolvedPublisherId as never)
    .executeTakeFirst();

  if (!publisher) {
    return {
      ok: false,
      message: "Forbidden: publisher not found for the public deploy.",
    };
  }

  if (!publisher.can_publish_public) {
    return {
      ok: false,
      message:
        `Forbidden: publisher "${publisher.name}" is not approved to publish ` +
        `to the public environment. Contact Plot to request public-publish access.`,
    };
  }

  return { ok: true };
}
```

> Note: `where("id", "=", resolvedPublisherId as never)` — `publisher.id` is a Kysely `bigint`/`Generated` column; the `as never` avoids the brand-type mismatch. If the existing codebase casts publisher ids differently (grep `where("publisher.id"` in `sdk/twist.ts` — it uses `as any` at line 458), match that style (`as any`) instead for consistency.

- [ ] **Step 4: Run the test to verify it passes**

Run: `pnpm --filter @plotday/api exec vitest run src/twist/public-deploy-auth.test.ts`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/twist/public-deploy-auth.ts workers/api/src/twist/public-deploy-auth.test.ts
git commit -m "feat(api): add public-deploy authorization helper"
```

---

## Task 3: Wire the helper into the deploy route; remove the dev shortcut

**Files:**
- Modify: `workers/api/src/sdk/twist.ts`

- [ ] **Step 1: Import the helper**

At the top of `workers/api/src/sdk/twist.ts`, near the existing `import { deployTwist } from "../twist/deployment";` (line 6), add:

```ts
import { checkPublicDeployAllowed } from "../twist/public-deploy-auth";
```

- [ ] **Step 2: Delete the dev-only public block**

Remove the entire block at `sdk/twist.ts:396-419` (the comment starts `// Direct deploys to "public" are a dev-only shortcut...` and ends with the closing brace of the `if (environment === "public") {` guard, just before the `// Determine the publisher that owns this package.` comment). Delete from:

```ts
    // Direct deploys to "public" are a dev-only shortcut for @plot.day users.
    // In production, public must be reached via the review → auto-approve flow.
    if (environment === "public") {
      ...
      if (!email.endsWith("@plot.day")) {
        return new Response(
          "Forbidden: only @plot.day users can deploy directly to public",
          { status: 403 }
        );
      }
    }
```

…through the closing `}` of that `if`. Leave the surrounding non-personal logic intact.

- [ ] **Step 3: Add the publisher-grant check after publisher resolution**

Immediately after the non-personal `if/else if/else` block that sets `resolvedPublisherId` ends (currently the `}` at `sdk/twist.ts:484`, right before `// Check if client wants streaming response`), insert:

```ts
  // Authorize public deploys: only publishers granted can_publish_public may
  // target the public environment. Replaces the former dev-only @plot.day
  // shortcut so the same rule applies in prod and dev.
  const publicDeployCheck = await checkPublicDeployAllowed(
    db,
    environment,
    resolvedPublisherId,
  );
  if (!publicDeployCheck.ok) {
    return new Response(publicDeployCheck.message, { status: 403 });
  }
```

(`db` is `c.var.db`, already in scope at `sdk/twist.ts:361`; `resolvedPublisherId` and `environment` are in scope.)

- [ ] **Step 4: Verify the old `ENV` reference is gone**

Run: `grep -n "ENV" workers/api/src/sdk/twist.ts`
Expected: no remaining reference to the removed `typeof ENV !== "undefined"` shortcut (if other unrelated `ENV` uses exist elsewhere in the file, that's fine — just confirm the deleted block's reference is gone).

- [ ] **Step 5: Typecheck and lint**

Run: `pnpm --filter @plotday/api lint`
Expected: passes (no type errors from the new import/usage).

- [ ] **Step 6: Run the api test suite for regressions**

Run: `pnpm --filter @plotday/api exec vitest run src/twist/public-deploy-auth.test.ts src/twist/deployment.test.ts`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add workers/api/src/sdk/twist.ts
git commit -m "feat(api): gate public deploys on publisher.can_publish_public"
```

---

## Task 4: Create the connector manifest

**Files:**
- Create: `connectors/deploy.json`

- [ ] **Step 1: List actual connector package names from both roots**

Run:

```bash
for d in connectors/*/package.json public/connectors/*/package.json; do
  [ -f "$d" ] || continue
  jq -e '.plotTwistId' "$d" >/dev/null 2>&1 && jq -r '.name' "$d"
done | sort
```

Expected: the full set of connector package names (e.g. `@plotday/connector-slack`, `@plotday/connector-linkedin`, …). Use these exact strings — do not hand-type names.

- [ ] **Step 2: Create `connectors/deploy.json` with the current public set + LinkedIn**

Create `connectors/deploy.json`. Populate `public` with the package names (verified in Step 1) that map to today's public connectors — Airtable, Attio, GitHub, Gmail, Google Calendar, Google Chat, Google Contacts, Google Drive, Google Tasks, Granola, Linear, Outlook Calendar, Slack — **plus** `@plotday/connector-linkedin`. Example (adjust names to match Step 1 output exactly):

```json
{
  "//": "Source of truth for which connectors deploy to the end-user-visible 'public' environment. Anything not listed deploys to 'review'. See docs/superpowers/specs/2026-06-10-git-driven-connector-publishing-design.md",
  "public": [
    "@plotday/connector-airtable",
    "@plotday/connector-attio",
    "@plotday/connector-github",
    "@plotday/connector-gmail",
    "@plotday/connector-google-calendar",
    "@plotday/connector-google-chat",
    "@plotday/connector-google-contacts",
    "@plotday/connector-google-drive",
    "@plotday/connector-google-tasks",
    "@plotday/connector-granola",
    "@plotday/connector-linear",
    "@plotday/connector-outlook-calendar",
    "@plotday/connector-slack",
    "@plotday/connector-linkedin"
  ]
}
```

- [ ] **Step 3: Validate it parses and every entry resolves to a discovered connector**

Run:

```bash
DISCOVERED=$(for d in connectors/*/package.json public/connectors/*/package.json; do
  [ -f "$d" ] || continue
  jq -e '.plotTwistId' "$d" >/dev/null 2>&1 && jq -r '.name' "$d"
done)
for name in $(jq -r '.public[]' connectors/deploy.json); do
  echo "$DISCOVERED" | grep -qxF "$name" || echo "MANIFEST ERROR: $name not found among connectors"
done
echo "validation done"
```

Expected: `validation done` with no `MANIFEST ERROR` lines.

- [ ] **Step 4: Cross-check against the current public set (no silent demotions)**

Confirm every connector that is public in prod today appears in the manifest (the list in Step 2). If you have prod DB access, compare against `SELECT name FROM twist WHERE environment='public' AND is_source=true;`. If not, eyeball against the Background-facts list above. A connector public today but missing here would stop receiving deploys.

- [ ] **Step 5: Commit**

```bash
git add connectors/deploy.json
git commit -m "feat(connectors): add deploy.json public-connector manifest"
```

---

## Task 5: CI — deploy private connectors + manifest-driven environment

**Files:**
- Modify: `.github/workflows/deploy-twists.yml`

- [ ] **Step 1: Discover connectors from both roots**

In `.github/workflows/deploy-twists.yml`, the "Discover all twists and connectors" step (lines 167–174), change the connector discovery glob to include the private root:

```bash
          # Discover connectors: directories in connectors/ or public/connectors/
          # with a plotTwistId in package.json
          ALL_CONNECTORS=()
          for dir in connectors/*/package.json public/connectors/*/package.json; do
            [ -f "$dir" ] || continue
            if jq -e '.plotTwistId' "$dir" > /dev/null 2>&1; then
              ALL_CONNECTORS+=("$(basename "$(dirname "$dir")")")
            fi
          done
```

- [ ] **Step 2: Accept private connectors in manual-dispatch validation**

In the "Check for affected twists and connectors" step, the manual-dispatch connector validation (line 226) checks only `public/connectors/$connector`. Change it to accept either root:

```bash
              for connector in "${INPUT_LIST[@]}"; do
                connector=$(echo "$connector" | xargs)
                if [ -d "connectors/$connector" ] || [ -d "public/connectors/$connector" ]; then
                  CONNECTORS_TO_DEPLOY+=("$connector")
                else
                  echo "Warning: connector '$connector' not found in connectors/ or public/connectors/"
                fi
              done
```

(The automatic "affected" detection at lines 285–289 already keys on the package name `@plotday/connector-$connector` via nx, which is location-independent — no change needed there.)

- [ ] **Step 3: Locate the connector dir from either root in the deploy job**

In the `deploy-connectors` job's "Read connector package name" step (lines 410–416), resolve the directory from either root and output both `dir` and `name`:

```yaml
      - name: Locate connector directory
        id: locate
        env:
          CONNECTOR: ${{ matrix.connector }}
        run: |
          if [ -d "connectors/$CONNECTOR" ]; then
            DIR="connectors/$CONNECTOR"
          elif [ -d "public/connectors/$CONNECTOR" ]; then
            DIR="public/connectors/$CONNECTOR"
          else
            echo "ERROR: connector $CONNECTOR not found in connectors/ or public/connectors/"
            exit 1
          fi
          NAME=$(jq -r '.name' "$DIR/package.json")
          echo "dir=$DIR" >> "$GITHUB_OUTPUT"
          echo "name=$NAME" >> "$GITHUB_OUTPUT"
          echo "Found connector $NAME at $DIR"
```

- [ ] **Step 4: Choose deploy environment from the manifest**

Replace the "Deploy ... connector" step (lines 438–441) so it reads `connectors/deploy.json` and targets `public` or `review`:

```yaml
      - name: Deploy ${{ matrix.connector }} connector
        env:
          NAME: ${{ steps.locate.outputs.name }}
        run: |
          if jq -e --arg n "$NAME" '.public | index($n)' connectors/deploy.json > /dev/null; then
            TARGET_ENV=public
          else
            TARGET_ENV=review
          fi
          echo "Deploying $NAME to $TARGET_ENV"
          cd ${{ steps.locate.outputs.dir }}
          pnpm plot deploy -e "$TARGET_ENV"
```

- [ ] **Step 5: Add a manifest-validation guard to the discover step**

At the end of the "Discover all twists and connectors" step (after the connector loop), fail fast if the manifest references an unknown connector:

```bash
          # Validate connectors/deploy.json: every listed package must be discovered.
          if [ -f connectors/deploy.json ]; then
            DISCOVERED_NAMES=""
            for dir in connectors/*/package.json public/connectors/*/package.json; do
              [ -f "$dir" ] || continue
              jq -e '.plotTwistId' "$dir" > /dev/null 2>&1 && DISCOVERED_NAMES+="$(jq -r '.name' "$dir")"$'\n'
            done
            MISSING=0
            for name in $(jq -r '.public[]' connectors/deploy.json); do
              if ! printf '%s' "$DISCOVERED_NAMES" | grep -qxF "$name"; then
                echo "::error::connectors/deploy.json lists unknown connector: $name"
                MISSING=1
              fi
            done
            [ "$MISSING" -eq 0 ] || exit 1
          fi
```

- [ ] **Step 6: Lint the workflow YAML locally**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/deploy-twists.yml')); print('yaml ok')"`
Expected: `yaml ok`

- [ ] **Step 7: Dry-run the manifest selection logic locally**

Run (mimics Step 4 selection for a known-public and a known-review connector):

```bash
for NAME in @plotday/connector-slack @plotday/connector-asana; do
  if jq -e --arg n "$NAME" '.public | index($n)' connectors/deploy.json > /dev/null; then echo "$NAME -> public"; else echo "$NAME -> review"; fi
done
```

Expected: `@plotday/connector-slack -> public` and `@plotday/connector-asana -> review` (Asana has no public row today; adjust the second name to any connector you left out of the manifest).

- [ ] **Step 8: Commit**

```bash
git add .github/workflows/deploy-twists.yml
git commit -m "ci: deploy private connectors and pick env from connectors/deploy.json"
```

---

## Task 6: CLI — surface `public` in `-e` help (public submodule)

**Files:**
- Modify: `public/twister/cli/index.ts:105-106` and `public/twister/cli/index.ts:130-131`
- Create: `public/.changeset/<name>.md`

> This is a `public/` submodule change → separate PR + changeset (see `AGENTS.md` → Changesets). The server enum already accepts `"public"`; this is help-text only.

- [ ] **Step 1: Create a branch in the submodule**

```bash
cd public && git checkout -b twister-public-env-help
```

- [ ] **Step 2: Update the deploy command help string**

In `public/twister/cli/index.ts`, the `deploy` command option (lines 105–106), change:

```ts
    "-e, --environment <env>",
    "Deployment environment (personal, private, review, public)",
```

- [ ] **Step 3: Update the logs command help string**

In the same file, the `logs` command option (lines 130–131), change:

```ts
    "-e, --environment <env>",
    "Twist environment (personal, private, review, public)",
```

- [ ] **Step 4: Add a changeset**

Create `public/.changeset/twister-public-env-help.md`:

```markdown
---
"@plotday/twister": patch
---

Changed: document the `public` value for the `-e/--environment` flag in `plot deploy` and `plot logs` help text.
```

- [ ] **Step 5: Validate the changeset and build**

Run: `cd public && pnpm validate-changesets`
Expected: passes.

Run: `cd public/twister && pnpm build`
Expected: builds cleanly.

- [ ] **Step 6: Commit (submodule)**

```bash
cd public && git add twister/cli/index.ts .changeset/twister-public-env-help.md
git commit -m "docs(cli): document public environment for -e flag"
```

(The submodule pointer bump in the core repo happens when this submodule PR merges — track it as a follow-up, do not bump to an unmerged commit.)

---

## Task 7: Finalization

- [ ] **Step 1: Run the finalize checklist**

Invoke `/finalize`. Confirm: `pnpm lint` clean in `workers/api` and `libs/db`; `captureException` is unaffected (the new `403` is an expected/handled response, not a caught unexpected error — no capture needed); `docs/updates.md` not needed (developer-infra change, not user-facing).

- [ ] **Step 2: Confirm DB sync and types**

Run: `pnpm diff-schema-migrations` (no diff) and `pnpm --filter @plotday/db run lint` (types in sync).

- [ ] **Step 3: Manual smoke (optional, local)**

With the local API worker running (`pnpm --filter @plotday/api dev`, `ENV=development`), confirm a `plot deploy -e public` for a connector now succeeds via the publisher grant (Plot publisher has the flag) rather than the deleted `@plot.day` shortcut, and that an unprivileged publisher gets the clear `403` message.

---

## Out-of-band prerequisite (not code — verify before LinkedIn goes live)

- [ ] **Unipile prod credentials.** LinkedIn is Unipile-backed (`connectors/linkedin`, `SCOPES = []`, depends on `@plotday/unipile`). Confirm Unipile API credentials exist in the **prod** API worker environment before the first public deploy lands. Without them, LinkedIn deploys public but cannot connect.

---

## Self-Review

**Spec coverage:**
- Manifest `connectors/deploy.json` → Task 4. ✅
- CI deploys private connectors → Task 5 (Steps 1–3). ✅
- Manifest drives deploy environment → Task 5 (Step 4). ✅
- `publisher.can_publish_public` column + Plot grant → Task 1. ✅
- API gate on the flag, replacing dev shortcut → Tasks 2–3. ✅
- Clear error for unapproved publishers → Task 2 (message) + Task 3 (wiring) + helper test asserts message. ✅
- CLI `public` help text + changeset → Task 6. ✅
- Manifest validation (no typos / silent review-drops) → Task 5 (Step 5) + Task 4 (Steps 3–4). ✅
- Non-goals (keep `auto_approve`, twist flow, `connections.ts`) — untouched by all tasks. ✅
- LinkedIn rollout → Task 4 (in manifest) + Unipile prereq. ✅

**Placeholder scan:** No TBD/TODO; every code/SQL/YAML step shows full content. Migration filename is `<timestamp>`-prefixed (Atlas-generated) — unavoidable and called out.

**Type consistency:** `checkPublicDeployAllowed(db, environment, resolvedPublisherId)` signature is identical in the helper (Task 2 Step 3), its test (Task 2 Step 1), and the route wiring (Task 3 Step 3). Return shape `{ ok: true } | { ok: false; message: string }` consistent across helper, test, and route. `resolvedPublisherId: number | null` matches the route's existing variable.
