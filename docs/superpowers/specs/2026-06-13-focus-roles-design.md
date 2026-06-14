# Focus Roles — Design Spec

**Date:** 2026-06-13
**Branch:** `focus-roles`
**Status:** Approved design, ready for implementation planning

## Overview

Group focuses under **roles** (e.g. *Work*, *Personal*). Every focus belongs to
exactly one role. A role carries a **name**, a **colour**, and **notification
settings**; its focuses *follow* the role's colour and notifications until the
user overrides them. Each role owns a single auto-managed **Inbox** focus.

This is deliberately a single level of grouping. There is **no** "all threads in
a role" view, and we are **removing** the legacy `priority.path` (ltree)
hierarchy and the single per-user root priority entirely. Grouping is expressed
solely through `priority.role_id`.

### Goals

- A first-class `role` entity that groups focuses and provides colour +
  notification templates.
- Colour/notification **propagation** to focuses that still match the role
  ("follow if matching"), with no UI "Inherit" toggle.
- A per-role **Inbox** focus that serves as the classifier's catch-all.
- The **thread classifier** uses role context and falls back to the matched
  role's Inbox (never a global root).
- A revised **onboarding first step** that creates/labels the user's first role.
- **Backfill** existing users into a *Personal* role.
- A **Role** field in the focus create/edit modal, plus an **Add role** modal.
- A **sidebar** that nests focuses under collapsible role headers when there is
  more than one role, with reverse-inherited status on collapsed roles and
  drag-reordering of both roles and focuses.

### Terminology

- **Role** — a grouping of focuses with a name, colour, and notification
  settings. New entity introduced by this work.
- **Focus** — user-facing name for a `priority` row. Belongs to one role.
- **Inbox** — the special auto-managed focus of a role (`priority.is_inbox`).
  Acts as the classifier catch-all for that role.

## Decisions (resolved during brainstorming)

1. **Storage:** a new `role` table plus `priority.role_id`. Not roles-as-priorities.
2. **Propagation:** *follow if matching* — focuses store concrete values and
   adopt role changes only while their value still equals the role's old value.
3. **Inbox:** a special, auto-managed focus (named "Inbox", not deletable,
   colour follows the role, reorderable but otherwise locked).
4. **Classifier fallback:** the matched role's Inbox; ultimate tiebreaker is the
   oldest role's Inbox.
5. **Role notification template:** notifications only — `early_notifications_enabled`,
   `notify_window`, `see_within`. Response-time and Pomodoro stay per-focus
   (response-time is a dead remnant and is left untouched).
6. **Role lifecycle:** archive-only-when-empty (cannot archive the last role).
7. **Role change for a focus:** modal-only.
8. **Dragging:** roles are drag-reorderable; focuses drag-reorder within their
   role. Cross-role focus drag is out of scope.
9. **Remove `priority.path` and the single root priority entirely.** Synthesize
   `path`/`root` only for older API versions (backward compatibility).
10. **"Everything"** lives inside the scrollable list, as the last row after
    "+ Add a focus" (no longer a fixed bottom tile).
11. **Old-client back-compat:** minimal no-crash synthetic `path`/`root` for
    API < 5 (the role-aware client = API v5); multi-role users degrade on old
    clients (acceptable — those builds predate roles).
12. **`*_set` flags:** dropped; the one remaining reader switches to
    `notify_window IS NOT NULL`.
13. **Migrations:** proper expand + contract split (CI-enforced).
14. **Sidebar drag:** nested reorderables (outer roles, inner focuses).

## Data model

### `role` table (new)

```
role(
  id          uuid primary key default uuidv7(),
  user_id     uuid not null references "user" on delete cascade,
  created_by  uuid not null references "user",
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  archived_at timestamptz,
  name        text not null,
  color       integer not null,          -- theme colour index 0–7
  "order"     double precision,          -- sidebar order; default = creation order
  -- notification template (the set focuses follow):
  early_notifications_enabled boolean,
  notify_window               jsonb,
  see_within                  jsonb,
  seq         xid8 not null              -- sync cursor (update_seq_and_updated_at trigger)
)
```

One row per role per user. Mirrors `priority`'s sync conventions (`seq`,
`updated_at`, soft-delete via `archived_at`).

### `priority` changes

- **Add** `role_id uuid not null references role(id)` — every focus belongs to a role.
- **Add** `is_inbox boolean not null default false` — marks the role's Inbox.
  Partial unique index: at most one live Inbox per role
  (`unique (role_id) where is_inbox and archived_at is null`).
- **`color`** becomes concrete and `not null` (resolved during backfill).
- **Drop** `path` (ltree) and `root`.
- `key` uniqueness moves from per-root-tree to **per-user**
  (replace `idx_priority_key_per_root`).

### Removals (path/root teardown)

Delete or rewrite everything that depended on the ltree hierarchy or the single
root:

- Root-validation trigger (the "exactly one depth-1 priority per user" guard).
- `effective_priority_id` — rewrite to resolve to the focus's **role's Inbox**
  (was: user's root) when a focus is archived/pending.
- `user.priority` view — drop `path`, `global_path`, `root`; add `role_id`,
  `is_inbox`.
- `priority_setting_inherited` view — **delete** (colour/notifications are now
  concrete + propagated, not inherited at read time).
- ltree indexes (`idx_priority_path_gist`, `idx_priority_user_path_unique`).
- Classifier `rootPriorityId` and the path-based hierarchy in
  `fetchPriorityHierarchies` (see Classifier section).
- Flutter: `Path` util + `PathConverter`, the `root` boolean, `ancestors()` /
  `parent` / `children`, `Priority.getDefault()`-as-root, and any
  `Path.generate(parent:)` callers.

> Confirm during planning that the `populate_thread_priority_*` and
> `file_thread_priority_*` triggers do **not** reference `path`/`root` (they
> filter on contacts/groups and should be unaffected), and audit all `user.*`
> views for `path`/`root`/`effective_priority_id` references.

## API backward compatibility

The sync layer already version-gates responses via the `X-Plot-API-Version`
header (currently `4`; `/sync/priorities` already transforms rows per version in
`projectPriority`, and v4 itself faked a "flat focus" shape). The role-aware
client bumps to **API v5**.

- **API v5+** clients receive `role_id` / `is_inbox` and no `path` / `root`.
- **API < 5** clients get a **minimal no-crash** legacy projection. Old apps
  treat `path` as a *required* Drift column, so a missing `path` crashes them; we
  must keep emitting a valid one. Since the physical columns are gone,
  `projectPriority` synthesizes them from role data: designate the user's oldest
  live Inbox as `root = true`, emit `everything` for it and `everything.<id-slug>`
  for the rest. We deliberately do **not** reconstruct grouping for old clients —
  multi-role users degrade there (extra Inboxes appear as ordinary focuses, no
  role grouping). Acceptable, since those builds predate roles.

Old Flutter clients already tolerate unknown extra columns (`fromBase()` strips
keys it doesn't model), so emitting new columns is harmless; the only hard rule
is never to drop `path`/`root` from the API < 5 response shape.

## Migration strategy (expand / contract)

Destructive DDL is CI-forbidden in `migrations/` (the Squawk gate), so the
change splits across two migrations. Both apply locally via
`pnpm apply-migrations`; in production the contract drains a deploy later, after
a soak.

- **Expand** (`migrations/`): create `role`; add `priority.role_id` (nullable,
  then backfilled) and `priority.is_inbox`; add propagation triggers; add the
  `user.role` view and `role_id`/`is_inbox` to `user.priority`; backfill Personal
  roles, adopt existing roots as Inboxes, and resolve concrete `priority.color`.
  `path` / `root` stay physically present but unused; the new code stops reading
  them.
- **Contract** (`migrations-contract/`): drop `priority.path`, `priority.root`,
  the ltree indexes, the root-validation trigger, the `priority_setting_inherited`
  view, and the dead `*_set` projections/columns; set `priority.role_id` and
  `priority.color` NOT NULL (after backfill has soaked).

Regenerate and commit `libs/db/src/types.ts` after applying.

## Propagation — "follow if matching"

Focuses store **concrete** colour and notification values. "Following" is
determined by **value equality**, not a hidden flag (matching "there is no
Inherit setting").

- **Role colour change** (old → new): a DB trigger sets `priority.color = new`
  for every live focus in the role whose `color = old`. Overridden focuses
  (`color ≠ old`) are untouched.
- **Role notifications change:** same rule, comparing the triple
  `(early_notifications_enabled, notify_window, see_within)`. Focuses whose
  triple equals the role's **old** triple adopt the new triple.
- **Focus reassigned to a new role** (via the modal): applied per dimension —
  if the focus matched its **old** role's value it adopts the **new** role's
  value (keeps following); an override is preserved. Colour and notifications
  are evaluated independently.
- The **Inbox** focus always follows its role (its colour/notifications are
  locked to the role).

Propagation bumps `priority.seq` so clients resync changed values. JSON
comparisons (`notify_window`, `see_within`) must normalise before comparing.

The legacy `*_set` flags (`early_notifications_enabled_set`, `notify_window_set`,
`see_within_set`, and the already-dead `respond_*_set`) lose all meaning and are
**dropped** — from the `user.priority` view, the Drift `Priorities` table, and
the generated API types. Their one remaining reader,
`notification_service.dart` (which queries `notifyWindowSet == true`), is
refactored to `notify_window IS NOT NULL`.

## Classifier integration

`libs/classifier/` + `workers/api/src/state/classify-thread.ts`.

- **Hierarchy = role.** `fetchPriorityHierarchies` sources
  `hierarchy_id` / `hierarchy_title` from `role` (id / name) instead of the
  ltree depth-2 ancestor. The cold-start and tiebreaker prompts already print a
  `hierarchy:` line; it now carries the role name. Account → hierarchy affinity
  aggregates by role.
- **Fallback = matched role's Inbox.** Replace `rootPriorityId`: when no
  specific focus is confident, pick the most likely role (origin / filing
  affinity) and return that role's `is_inbox` focus. Ultimate tiebreaker: the
  **oldest** role's Inbox — guarantees every thread has a home.
- `effective_priority_id` (archived/pending focus → fallback) resolves to the
  focus's role's Inbox.

## Backfill & activation

### Backfill migration (existing users)

Per user:

1. Create a **Personal** role: `color = 0` (theme 0), default notifications.
2. Set `role_id = Personal` on all the user's focuses.
3. Convert the existing root priority into the Personal **Inbox**
   (`is_inbox = true`, `role_id = Personal`). **No threads move.**
4. Resolve concrete `priority.color` (NULL → theme 0; existing non-matching
   colours/notifications remain as overrides).

Then drop `path` / `root` / the root trigger / ltree indexes.

> Current model already has focuses flat at depth 2 under a single root, so
> there is no deep nesting to flatten.

### Activation (new users)

User activation creates a Personal role + its Inbox focus directly (no root
concept), guaranteeing every user always has ≥1 role and no role-less focus.

## Onboarding — first step

Activation yields one default role. The first interactive onboarding step
becomes a single-select:

> **Where do you want to use Plot first?** — Work · Personal · Volunteering ·
> School · Other

A conditional follow-up text input, then `onBeforeNext` **configures the
existing default role** (rename + keep theme 0). It does **not** create a second
role, so new users stay single-role (flat sidebar).

| Choice | Follow-up (placeholder) | Resulting role name |
|---|---|---|
| Work | "Where do you work?" (*Acme Co*) | the answer |
| Personal | — (skip) | "Personal" |
| Volunteering | "Where do you volunteer?" (*The Kindness Project*) | the answer |
| School | — (skip) | "School" |
| Other | "What should we call this role?" (*Superhero*) | the answer |

Colour is theme 0 in all cases. Seeded welcome threads land in that role's Inbox
automatically (they are already under the adopted root → Inbox).

Reuse existing onboarding widgets: single-select option cards and the
`FormTextInput` + placeholder pattern.

## Focus create/edit modal

`apps/plot/lib/command/priority.dart`.

- Add a **required** `FormSelect<Role>` **Role** field. It lists each role with
  its `ColorDot` + name, plus an **"Add role"** action (`onAdd`).
- **Add role** opens a small modal collecting **name + colour only** (no
  notifications), creates the role, and selects it. Reuse the existing
  `FormSelect<ThemeColor>` colour-picker pattern (`ColorDot`, grid mode).
- **Modal interaction:** when the user changes **Role**, the **Colour** field
  auto-updates to the new role's colour *if the focus was following* (matched
  the old role); an overridden colour stays. This previews the follow-if-matching
  result before save.
- On save, role/colour/notification changes apply the propagation rules
  (server trigger authoritative; client optimistic update mirrors).
- "+ Add a focus" defaults the new focus's Role to the current/expanded role.

## Sidebar

`apps/plot/lib/widget/priorities_list.dart` (+ `priority.dart`,
`state/priorities*.dart`).

```
ONE role (unchanged):                      MULTIPLE roles (accordion):
┌──────────────────────┐                   ┌──────────────────────┐
│  Acme Project     •   │ ┐ scroll          │ ⠿ ▾ Work             │ ┐
│  Hiring               │ │                 │      Acme Project •  │ │
│  Inbox                │ │                 │      Hiring          │ │ within-role drag
│  + Add a focus        │ │                 │      Inbox           │ │
│  Everything           │ ┘                 │ ⠿ ▸ Personal      •  │ │ scroll
└──────────────────────┘                   │ ⠿ ▸ Volunteering     │ │
                                            │  + Add a focus       │ │
                                            │  Everything          │ ┘
                                            └──────────────────────┘
                                              ⠿ = drag roles to reorder
```

- **One role:** no header; focuses flat exactly like today (Inbox at the bottom
  by default, reorderable).
- **Multiple roles:** **accordion** — only the role containing the selected
  focus is expanded; all others collapsed. Header shows the role name in the
  role's (muted) colour + a caret.
- **Expand/collapse is animated.** Switching the expanded role animates the
  caret rotation and the focuses sliding/fading in and out (e.g. an
  `AnimatedSize` / size+fade transition), rather than snapping. Because it's an
  accordion, opening one role and closing the previous one animate together.
- **Collapsed roles reverse-inherit** (computed client-side from the role's
  focuses): **bold** if any child would be bold (child active), **notification
  dot** if any child has unread.
- **Clicking a collapsed role** expands it and selects its **first** focus
  (first by order; the Inbox is last).
- **Role "…" menu:** *Edit role* (name + colour) and *Notifications* (the role
  template, reusing the existing notifications modal).
- **Drag:** roles drag-reorder (persist to `role.order` via `Order.between`);
  focuses drag-reorder within their role. Implementation: **nested
  reorderables** — an outer reorderable list of role headers, with an inner
  reorderable for the one expanded role's focuses (only one role is open at a
  time). Cross-role focus drag is out of scope.
- **"Everything"** is the last row inside the scrollable, after "+ Add a focus".
- The old fixed global **Inbox** tile is removed (per-role Inboxes replace it).

## Sync / Flutter store

- New `user.role` view, `/sync/roles` endpoint, Drift `Roles` table + `Role`
  entity (mirror `Priorities`/`Priority` conventions).
- `user.priority` view + Drift `Priorities` gain `role_id` + `is_inbox`; drop
  `path`/`root` (with synthetic projection for old API versions).
- Reverse-inherit is pure client computation (no server work).
- Regenerate `libs/db/src/types.ts` after schema changes; commit it.

## Out of scope (v1)

- Cross-role focus drag (role change is modal-only).
- Any "all threads in a role" aggregated view.
- Response-time / Pomodoro as role templates.
- Role deletion beyond archive-when-empty.
- Creating multiple roles during onboarding.

## Affected surface (inventory for planning)

- **Schema:** `libs/db/schema/50-tables/22-priority.sql` (+ new `role` table),
  `70-views/15-priority.sql` (delete `priority_setting_inherited`),
  `90-user-schema/22-priority.sql` (+ new `90-user-schema/role` view),
  `90-user-schema/05-effective_priority_id.sql`, root-validation trigger,
  `priority_block` ordering, `95-triggers/*` (new propagation triggers).
- **Migrations:** expand migration for `role` + `priority` columns + backfill;
  contract migration for dropping `path`/`root`/indexes/`priority_setting_inherited`
  after workers stop reading them.
- **Classifier:** `libs/classifier/src/ts-hybrid-accounts.ts`,
  `ts-hybrid-stages.ts`, `ts-hybrid-scoring.ts`, prompt builders.
- **API sync:** `workers/api/src/app/sync/*` (roles endpoint, versioned priority
  projection), thread-helpers classification target.
- **Flutter store:** `apps/plot/lib/store/priority.dart` (+ new `role.dart`),
  `apps/plot/lib/util/path.dart` (remove), `theme_color.dart`,
  `apps/plot/lib/util/order.dart`.
- **Flutter UI:** `apps/plot/lib/widget/priorities_list.dart`,
  `widget/priority.dart`, `command/priority.dart` (+ Add role),
  `command/early_notifications.dart` (role variant), `state/priorities*.dart`,
  `state/now.dart` (selection / accordion).
- **Onboarding:** `apps/plot/lib/widget/onboarding/onboarding_steps.dart`,
  `state/onboarding*.dart`, plus the seed/activation path.
- **Docs:** `docs/updates.md`, `docs/features.md`.

## Resolved decisions (formerly open questions)

1. **API back-compat:** mechanism confirmed — `X-Plot-API-Version` (bump to v5);
   serve **minimal no-crash** synthetic `path`/`root` to API < 5 (see *API
   backward compatibility*). Multi-role degrades on old clients — acceptable.
2. **`*_set` flags:** **dropped**; the one `notification_service` reader switches
   to `notify_window IS NOT NULL`.
3. **Migration split:** **proper expand + contract** (see *Migration strategy*).
4. **Sidebar reorder:** **nested reorderables** (outer roles, inner focuses).

## Remaining planning-time verifications

- Audit all `user.*` views and triggers for `path` / `root` /
  `effective_priority_id` references before the contract drop (confirm
  `populate_thread_priority_*` / `file_thread_priority_*` don't depend on path).
- Confirm `priority.role_id` / `priority.color` `SET NOT NULL` placement (expand
  vs. contract) passes the Squawk gate.
