# Onboarding "Connect your tools" — sectioned connectors + data-driven categories

**Date:** 2026-06-08
**Status:** Approved design, ready for implementation plan

## Goal

Rework the onboarding "Connect your tools" step (the former separate
"Connect your calendar" step has already been removed) so that the single
step lists every connector, organized into three sections — **Messaging**,
**Calendars**, and **Apps** (everything else) — and adds plan-limit copy at
the bottom with a tappable "Upgrade to Plot Pro" link.

To drive the grouping cleanly and extensibly, introduce a data-driven
`category` on connectors that flows from each connector's `package.json`
through the deploy pipeline into the `twist` record and out to the Flutter
app. The category set is deliberately open-ended so future categories (e.g.
task managers, read-later apps used as default sinks) can be added later
without re-architecting — those future categories are **not** designed here.

## Non-goals

- Designing default-sink configuration for task-manager / read-later
  categories. We only reserve the concept; we don't build it.
- Changing the connector auth/setup flow. Tiles continue to use the standard
  `AddSourceDetail` → `EditSource` modal flow.
- Any change to the upgrade/billing backend. We reuse the existing
  `ShowUpgradeOptions` / `BuyPlanCommand` infrastructure as-is.

## Design

### 1. Data model: `twist.category`

A new nullable `category` (text) column on the `twist` table, populated
through the same path that `description` and `logo_url` already travel.

- **Connector `package.json`** declares `"category": "messaging"` or
  `"category": "calendar"`. Documented known values *now*: `messaging`,
  `calendar`. Reserved for later (documented, not implemented): `tasks`,
  `read_later`, and other functional categories. Absent or unknown values
  are treated as a generic app.
- **CLI** (`public/twister/cli/commands/deploy.ts`): read
  `packageJson.category` alongside the existing `description` / `logoUrl`
  extraction and include it in the deploy request body.
- **API deploy** (`workers/api/src/twist/deployment.ts` `deployTwist()` and
  the `POST /v1/twist/:id` route): accept `category` and persist it to
  `twist.category` on **both** the INSERT and UPDATE branches (mirrors how
  `description` / `logo_url` / `logo_url_dark` are handled).
- **`/twists` catalog** (`getAllTwists` in `workers/api/src/app/twists.ts`):
  add `twist.category` to the column select and to the mapped JSON response.
- **Flutter `Twist`** (`apps/plot/lib/api/twist_api.dart`): add
  `final String? category;`, parsed from `json['category']` in
  `Twist.fromJson`.

The SDK/package.json remains the source of truth, and adding a future
category is just a new string — no schema or API change required.

### 2. Populating existing rows

No data backfill. Existing `twist` rows get their `category` when their
connectors are **redeployed** with the new `package.json` field. Until a
connector is redeployed its `category` is `null` and it shows under **Apps**
— acceptable graceful degradation. The column-adding migration therefore only
adds the nullable column (no `UPDATE`s).

Follow the project schema-change workflow: edit `libs/db/schema/`, run
`pnpm gen-migration`, `pnpm apply-migrations`, and commit the regenerated
`libs/db/src/types.ts`.

### 3. Connector `package.json` sweep

Add the `category` field to every connector's `package.json`:

- `public/connectors/*` (public submodule): gmail, slack, google-chat,
  ms-teams → `messaging`; google-calendar, outlook-calendar, apple-calendar
  → `calendar`. All remaining public connectors (airtable, asana, attio,
  fellow, github, google-contacts, google-drive, google-tasks, granola, jira,
  linear, notion, posthog, todoist) get **no** `category` (they fall into
  Apps). (Optional: set the obvious future ones now, but per non-goals we
  leave them uncategorized to avoid implying behavior we haven't built.)
- `connectors/*` (private, repo root): instagram, linkedin, whatsapp →
  `messaging`.

Public-submodule changes ship as a **separate PR** with a **changeset** for
the Twister CLI behavior change (new feature → `minor`).

### 4. Onboarding UI: `apps/plot/lib/widget/onboarding/onboarding_tools.dart`

- Remove the `_calendarPackageIds` exclusion so calendars render in this step
  too, using the standard `AddSourceDetail` tile flow like every other
  connector.
- Delete the now-dead `onboarding_calendars.dart` and its unused import in
  `onboarding_steps.dart`.
- Bucket the available connector tiles by `twist.category`:
  - `messaging` → **Messaging**
  - `calendar` → **Calendars**
  - everything else (including `null`/unknown) → **Apps**
- Render each non-empty bucket with a small section header above its `Wrap`
  of tiles; hide empty sections. Within a section, keep the existing
  alphabetical sort.
- Connected-source rows stay at the top, unchanged (existing behavior:
  connected sources show as check-marked rows; the section grids continue to
  list all available connectors).

### 5. Plan-limit copy + upgrade link

Below all sections, a centered paragraph styled to match the onboarding
overlay (white text):

> Add up to five connections on Plot Core, which you can try for 30 days. You
> can always use two connections for free. **Upgrade to Plot Pro** for
> unlimited connections.

- "Upgrade to Plot Pro" is a link-styled tappable span. Implement with
  `Text.rich` + a `TapGestureRecognizer` inside a small `StatefulWidget` so
  the recognizer is disposed properly.
- On tap, run the existing `ShowUpgradeOptions().run(context)` command. This
  was chosen over calling `BuyPlanCommand(plan:'pro')` directly because
  `ShowUpgradeOptions` already carries Apple's required subscription
  disclosure (auto-renew + Terms/Privacy) on App Store builds and routes to
  StoreKit (App Store) or the web upgrade URL (elsewhere) via
  `BuyPlanCommand`. No new disclosure UI is needed.

## Affected files (summary)

**Public submodule (`public/`) — separate PR + changeset:**

- `public/twister/cli/commands/deploy.ts` — read & send `category`
- `public/connectors/{gmail,slack,google-chat,ms-teams}/package.json` —
  `category: messaging`
- `public/connectors/{google-calendar,outlook-calendar,apple-calendar}/package.json`
  — `category: calendar`
- `public/.changeset/<name>.md` — minor

**Private repo:**

- `libs/db/schema/50-tables/90-twist.sql` — add `category` column
- `libs/db/migrations/<generated>.sql` — add nullable column (no backfill)
- `libs/db/src/types.ts` — regenerated
- `workers/api/src/twist/deployment.ts` — accept/persist `category`
- `workers/api/src/app/twists.ts` (and the deploy route handler) — select &
  return `category`; parse from deploy body
- `workers/api/src/db-types.ts` — regenerated/updated `twist.category`
- `connectors/{instagram,linkedin,whatsapp}/package.json` —
  `category: messaging`
- `apps/plot/lib/api/twist_api.dart` — `Twist.category`
- `apps/plot/lib/widget/onboarding/onboarding_tools.dart` — sectioning +
  upgrade copy
- `apps/plot/lib/widget/onboarding/onboarding_steps.dart` — drop unused
  calendar import
- `apps/plot/lib/widget/onboarding/onboarding_calendars.dart` — delete

## Testing

- `flutter analyze` clean; run-app verification of the sectioned step and the
  upgrade link (picker opens; web build opens upgrade URL).
- Workers: `pnpm lint` + existing deploy tests; add a focused test asserting
  `category` round-trips through deploy → `twist` row → `/twists` if a deploy
  test harness exists.
- DB: `pnpm diff-schema-migrations` clean; `pnpm --filter @plotday/db run
  lint` (types in sync).

## Open items deferred

- Default-sink behavior for `tasks` / `read_later` categories — future work.
- Redeploying connectors to populate `category` (in dev and prod) is the only
  way existing `twist` rows get a category — there is no backfill. Deploy
  itself is out of scope for this change; until a connector is redeployed it
  shows under **Apps**.
