# FYI Focus — Design Spec

**Date:** 2026-06-14
**Status:** Approved design, pending implementation plan
**Scope:** Backend (classifier + DB + API sync) **and** Flutter app (sidebar +
store entity). Builds directly on the **focus-roles** work.
**Sequencing:** Implementation is **gated on `focus-roles` merging to `main`**
(see §11). This spec and its plan are written against post-focus-roles `main`.

## 1. Problem

After focus-roles, every focus belongs to a role and each role owns an **Inbox**
that catches whatever the classifier can't place confidently. But the Inbox is
also where a lot of *non-actionable, low-urgency* mail ends up — promotions,
newsletters/long-form reading, bulk-sent updates, receipts, and non-actionable
notifications. That noise dilutes the Inbox, which should be **high-signal,
primarily human collaboration**.

We want a single, global **FYI** focus that the classifier uses as the home for
this low-signal traffic, so the role Inboxes stay clean and FYI can be **processed
less frequently**. Users can move threads **out of** FYI (or into it), and that
should teach the classifier to route similar threads the same way going forward.

## 2. How it fits focus-roles

focus-roles introduced:

- a `role` table and `priority.role_id` (every focus belongs to a role),
- `priority.is_inbox` — one auto-managed Inbox focus per role,
- a role-aware classifier whose fallback is the **matched role's Inbox**
  (`rootPriorityId()` in `workers/api/src/state/classify-thread.ts` resolves to
  the user's oldest live role's Inbox; ultimate tiebreaker), and
- an accordion sidebar (`apps/plot/lib/widget/priorities_list.dart`) where
  **"Everything"** is the last row, after "+ Add a focus".

FYI is deliberately **not** a per-role concept. It is **one global, role-less
focus per user**, sitting *outside* the role accordion, just above "Everything".
It is a positive routing target inserted ahead of the role-Inbox fallback — not a
replacement for it.

This also builds on the **thread-facet classification** work
(`docs/superpowers/specs/2026-06-08-thread-facet-classification-design.md`):
threads already carry server-only `thread.facets` (`format` / `automation` /
`reach`), extracted deterministically at the connector source by
`public/libs/email-classifier/`. **Facets are never synced to the client** — FYI
routing is a pure server-side classifier decision; the app only ever sees the
resulting `thread_priority` filing.

## 3. Data model

FYI is a **real `priority` row** (not a synthetic feed like "Everything"): the
classifier must *file* threads into it (`thread_priority.priority_id`) and the
user must move threads in/out, both of which require a concrete focus id.

### `priority` changes

- **Add `is_fyi boolean not null default false`** — marks the global FYI focus,
  mirroring `is_inbox`.
- The FYI focus is **role-less**: `role_id = NULL`, `is_inbox = FALSE`,
  `is_fyi = TRUE`, `title = 'FYI'`, stable `key = 'fyi'` (per-user unique key,
  per focus-roles' move of key uniqueness to per-user).
- **Partial unique index:** at most one live FYI per user —
  `unique (user_id) where is_fyi and archived_at is null`.
- Not archivable, not deletable, not reorderable into the role list (it renders
  in a fixed global position — see §7).

### Coordination with the focus-roles contract migration

focus-roles' **contract** migration (`migrations-contract/`, plan 6, **not yet
written**) plans `priority.role_id SET NOT NULL`. FYI requires `role_id` NULL, so
that becomes a check constraint instead:

```sql
ALTER TABLE public.priority
  ADD CONSTRAINT priority_role_or_fyi
  CHECK (role_id IS NOT NULL OR is_fyi);
```

This is an explicit **coordination point**: whichever lands second adjusts the
constraint. If focus-roles' contract already set `role_id NOT NULL` by the time
FYI is implemented, FYI's migration drops that and adds the check above.

## 4. Classification / routing

A **new deterministic stage** in the `ts-hybrid` cascade (`libs/classifier/`),
slotted between the explicit/structural stages and the soft scoring + fallback.

### Stage placement (precedence, highest → lowest)

1. `priority:` prefix
2. keyed priority (cross-user same-key)
3. priority title override (Jaccard)
4. **topic short-circuit** (mode priority learned from `user_moved`) ← learning
5. channel default (channel-scoped → channel's focus)
6. **NEW: FYI low-signal stage** ← *this work*
7. scoring (semantic / contact / group affinity over `user_moved` neighbors)
8. role-Inbox fallback (matched role's Inbox; oldest-role tiebreaker)
9. none

FYI sits at **stage 6** — it **beats** soft scoring (7) and the Inbox fallback
(8), satisfying "FYI wins for low-signal", but it **yields** to every explicit /
structural / learned-topic stage above it (1–5).

### FYI stage rule

Route the candidate to FYI **iff both**:

1. `thread.facets.format ∈ FYI_FORMATS`, where `FYI_FORMATS` is a single tunable
   constant:

   ```
   FYI_FORMATS = { promotion, reading, receipt, notification }
   ```

   — i.e. "everything but `message` and `chat`" (human collaboration), and
   excluding the actionable formats by construction (see carve-outs).
2. The sender does **not** already have a learned **real-focus home** — there is
   no non-FYI focus the sender is *trusted-for* (the user has previously moved
   that sender's mail into, or composed it into, a real focus). This reuses the
   existing trusted-for-focus signal from facet classification
   (`is_trusted_for_focus` in `libs/db/schema/60-functions/facet_gate.sql`,
   generalized to "any non-FYI, non-Inbox focus").

If (1) holds but (2) fails, the stage **yields** (returns no decision) so the
downstream scoring stage routes the thread to the learned focus. If (1) fails,
FYI never applies.

### Fail-open & carve-outs (actionable stays out)

- **Null/unknown `format` never routes to FYI.** Calendar, Drive, Linear, and
  human email the heuristic was unsure about leave `format` null and are
  untouched (consistent with the facet system's fail-open philosophy).
- **`invoice` is excluded** (bills you must pay are actionable) — it's simply not
  in `FYI_FORMATS`.
- **`otp` / `confirm` are excluded.** The OTP/confirm work
  (`docs/superpowers/specs/2026-06-14-otp-confirm-detection-and-toast-design.md`,
  §4.7) gives these their own `format` values, so an OTP that previously
  classified as `notification` now classifies as `otp` and never matches
  `FYI_FORMATS`. **Sequencing dependency:** see §11 — until those formats exist,
  actionable OTP/confirm emails classify as `notification` and *would* be swept
  into FYI. FYI must land after (or alongside) the OTP format addition. Fallback
  if they must ship independently: also exclude any thread whose originating note
  carries a `cta`.

### Why a stage and not a `facet_filters` gate

`priority.facet_filters` is an **exclusionary gate** applied only in the scoring
stage — it removes focuses from candidates, it does not *pull* threads into a
focus. FYI needs **positive** routing, so it is a dedicated stage with an
explicit, tunable predicate rather than a filter on the FYI focus.

## 5. Learning (reuse `user_moved`, both directions)

No new tables and no negative-signal storage — FYI rides the existing
`thread_priority.user_moved` machinery.

- **Move *out* of FYI → similar threads follow.** Moving a thread into a real
  focus sets `user_moved = TRUE`, which trains the two stages that outrank FYI:
  - **Topic short-circuit (stage 4):** if moved threads share a `topic`, future
    same-topic threads route to the learned focus before FYI is reached.
  - **Trusted-for-focus sender (stage 6 yield):** once the sender is trusted for
    a real focus, the FYI stage yields and scoring routes there.

  So after moving a few newsletters-from-X into "Reading", future
  newsletters-from-X go to Reading, not FYI.

- **Move *into* FYI → teaches FYI-worthy.** Marks FYI as a `user_moved` home for
  that thread/sender, making FYI a scoring/short-circuit target the same way any
  focus becomes one. (The stage-6 yield only checks *non-FYI* homes, so a thread
  whose sender is trusted *only* for FYI still routes to FYI.)

## 6. Notifications

FYI is **muted by default**: created with `early_notifications_enabled = false`
and no notify window — no push, no app badge. Because it is role-less it does
**not** follow any role notification template; it holds its own concrete
(muted) settings. The user can turn notifications on like any focus.

## 7. Sidebar & unread

`apps/plot/lib/widget/priorities_list.dart`.

- FYI renders as a **fixed global row between "+ Add a focus" and "Everything"**,
  *outside* the role accordion (it is role-less, so it is excluded from the
  per-role nested lists and from cross-role/flat focus sorting).
- Layout becomes: role accordion (or flat focuses) → "+ Add a focus" → **FYI** →
  "Everything".
- **Unread:** FYI shows a subtle unread indicator (so you know there's something
  to skim) but **never bolds** and **never contributes to the app badge** —
  matching "processed less frequently". FYI threads still appear in *Everything*.
- FYI is not part of the reorderable list (no drag handle); its position is
  fixed.

## 8. Sync / Flutter store

- `priority.is_fyi` is added to the `user.priority` view and the Drift
  `Priorities` table + `Priority` entity (mirroring `is_inbox`).
- API priority projection (`workers/api/src/app/sync/*`): emit `is_fyi` to API
  v5+ clients. For API < 5 (pre-roles clients), FYI degrades to an ordinary
  focus in the synthetic projection — acceptable, same posture as multi-role
  degradation in focus-roles.
- No facet plumbing to the client (facets stay server-only).
- Regenerate and commit `libs/db/src/types.ts` after schema changes.

## 9. Backfill & activation

- **Activation (new users):** the activation path that creates the Personal role
  + its Inbox also creates the global FYI focus (`is_fyi = TRUE`, role-less,
  muted). Every user always has exactly one FYI.
- **Backfill (existing users):** one **expand** migration creates an FYI focus
  per existing user. **No threads move** on backfill — routing is going-forward
  only (consistent with the facet rollout, which only populates facets on
  newly-synced threads).

## 10. Scope

**In:**

- Email (Gmail, Outlook-mail) and any source that emits facets. Slack
  `notification`-format threads are in scope; Slack `chat` / `message` stay in
  the Inbox.
- The new `is_fyi` focus, the FYI classifier stage, muted notifications, sidebar
  placement, sync of `is_fyi`, backfill + activation.

**Out (v1):**

- Per-role FYI (it is global).
- LLM-based FYI detection (deterministic facets only).
- A negative ("not-FYI") learning signal (reuse `user_moved`).
- Deep re-tuning of the `promotion` / `notification` extraction heuristics — the
  `FYI_FORMATS` constant is the v1 dial. `notification` is the flagged first
  candidate to narrow if it proves too broad.
- Cross-source facets beyond email/Slack (Calendar/Drive/Linear leave `format`
  null and are never FYI'd).

## 11. Dependencies & sequencing

1. **focus-roles must merge to `main` first** (provides `role`, `role_id`,
   `is_inbox`, role-aware classifier, accordion sidebar). This spec/plan are
   written against that state.
2. **Coordinate the `role_id` constraint** with focus-roles' contract migration
   (§3): `CHECK (role_id IS NOT NULL OR is_fyi)` instead of plain `NOT NULL`.
3. **OTP/confirm formats** (§4 carve-outs): land FYI after/with them, or apply
   the `cta` fallback exclusion, so actionable codes/confirms aren't swept into
   FYI.

## 12. Affected surface (inventory for planning)

- **Schema:** `libs/db/schema/50-tables/22-priority.sql` (`is_fyi` column +
  partial unique index + check constraint), `90-user-schema/22-priority.sql`
  (`is_fyi` in `user.priority`), activation function (create FYI focus).
- **Migrations:** expand migration for `is_fyi` + per-user FYI backfill;
  constraint coordination with focus-roles contract.
- **Classifier:** `libs/classifier/src/ts-hybrid.ts` (new FYI stage),
  `ts-hybrid-stages.ts` (FYI predicate / trusted-for-real-focus helper),
  `workers/api/src/state/classify-thread.ts` (candidate already carries
  `facets`; ensure FYI focus id is resolvable). `FYI_FORMATS` constant.
- **Trusted-for-focus helper:** `libs/db/schema/60-functions/facet_gate.sql`
  (generalize `is_trusted_for_focus` to "any non-FYI focus" / add a
  `sender_has_real_focus_home` predicate).
- **API sync:** `workers/api/src/app/sync/*` (emit `is_fyi`; v<5 projection).
- **Flutter store:** `apps/plot/lib/store/priority.dart` (`isFyi` field).
- **Flutter UI:** `apps/plot/lib/widget/priorities_list.dart` (fixed FYI row +
  unread treatment), selection/state where focuses are listed.
- **Activation/onboarding:** the activation path that seeds the default role +
  Inbox (create FYI alongside).
- **Docs:** `docs/updates.md`, `docs/features.md`.

## 13. Open questions / tuning notes

- **`notification` breadth.** Flagged by the user as possibly too broad. v1 keeps
  it in `FYI_FORMATS`; first dial to turn if FYI catches actionable
  notifications. Watch the interaction with the OTP/confirm carve-out (which
  removes the most actionable subset).
- **`reach` as a secondary guard.** If `format` alone over-captures, consider
  also requiring `reach = list` and/or `automation = automated` for the
  `notification` member specifically. Left out of v1 for simplicity; the
  predicate is one place to add it.
- **Exact "real-focus home" predicate** (stage-6 yield): confirm during planning
  whether to reuse `is_trusted_for_focus` per-focus in a `NOT EXISTS` over
  non-FYI focuses, or add a dedicated `sender_has_real_focus_home(user, author)`
  helper. Index coverage already exists
  (`idx_thread_priority_user_moved`, `idx_thread_contacts`).
- **Unread indicator styling** — exact "subtle, non-bolding, non-badging"
  treatment to be finalized against the focus-roles sidebar styling.

## 14. Finalize checklist (for implementation)

- `pnpm lint` in changed packages; `pnpm diff-schema-migrations` clean;
  `pnpm --filter @plotday/db run lint` (committed `types.ts`).
- Backward-compat: `is_fyi` additive; v<5 projection unaffected; old clients see
  FYI as an ordinary focus.
- `captureException` in any new TS catch blocks.
- `docs/updates.md`: user-facing line ("Low-signal mail — promotions,
  newsletters, receipts, notifications — now collects in a new **FYI** focus so
  your Inbox stays focused on people").
- `docs/features.md`: note the FYI focus.
- No `public/` submodule change expected (facet extraction already emits the
  needed formats; OTP/confirm formats ship in their own effort).
