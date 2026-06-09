# Connection-origin as a learned classification signal

**Date:** 2026-06-09
**Status:** Design (approved in brainstorming; pending spec review)
**Related:** [[2026-06-08-thread-facet-classification-design]] (facets, the facet gate, freemail/`domain` table, going-forward rollout convention)

## Problem

The classifier ignores **which connection a thread arrived through**. Two
threads that look alike by content, embedding, and even format facet — e.g. a
purchase receipt — differ in exactly one structured, high-signal way: the
mailbox/account they came in on. A receipt to the user's **work** email belongs
in their "Acme admin" focus; an identical-looking receipt to their **personal**
email belongs in "Personal finance". Today the classifier has no way to tell
them apart, so it leans on embeddings/contacts and routes unreliably.

The originating connection is the cheapest, sharpest discriminator available and
it is already recoverable: a connector thread has `thread.created_by =
twist_instance.id` (the connection). We just never use it.

## Goals

- Use the originating connection as a classification signal so receipts (and
  everything else) route to the focus that has seen that mailbox before.
- **No connection labels, no new onboarding UI** — the signal is learned from
  the user's own filings, exactly like the existing scoring signals.
- Transfer across a user's connections for the *same* org (work Gmail ↔ work
  Slack) without merging unrelated personal accounts.
- Learn from explicit reclassifications for free.
- Keep cross-categorization easy: a personal receipt that happens to be
  work-related must still be routable into the work focus with one move.

## Non-goals (explicitly out of scope for v1)

- **No user-facing role labels** on connections.
- **No description-derived role prior (L3).** The focus description still helps
  indirectly — role words in it steer the embedding/LLM rerank at focus
  creation, so the right threads get picked and seed the right origins — but it
  does not drive a separate scoring prior. Deferred; may revisit.
- **No hard gating on origin.** Origin is a soft scoring boost only, never an
  exclude, so cross-categorization stays a one-tap move.
- **No backfill.** Going-forward only, consistent with the facet rollout.

## Design

### Two layers of learned origin affinity

Both layers are evaluated inside the **scoring stage** of
`classify_thread_for_user_explain` (stages 1–2.5 — topic short-circuit, keyed
priority, channel default — still win first; `priority_prefix` and
`root_fallback` are unchanged). Origin is a **per-pair** term added to the
existing combined score against each `user_moved` example, mirroring how
`con`/`grp` already work.

**L1 — Exact-connection affinity.** For a candidate thread from connection `K`,
a `user_moved` example thread *also* from `K` contributes the largest origin
boost. This is the receipts workhorse: once "Personal finance" holds a receipt
moved in from personal Gmail, the next personal-Gmail receipt scores there;
"Acme admin" accrues work-Gmail receipts the same way.

**L2 — Org-group affinity.** Resolve each connection to an **org key** so a
user's work connections merge:

1. non-freemail **account domain** → `domain:<domain>` (e.g. `domain:acme.com`)
2. else **team-owned** connection → `team:<team_id>`
3. else (freemail account, no team) → **no org key** (no merge; L2 contributes
   nothing, L1 still applies)

A `user_moved` example sharing the candidate's org key (but not the exact
connection) contributes a smaller boost → work-Gmail ↔ work-Slack transfer,
while two distinct personal freemail accounts never merge.

Per-pair origin contribution (candidate connection `c`, example connection `f`):

```
origin(f, c) =
  EXACT_W   if c IS NOT NULL AND f = c
  ORG_W     elif org_key(f) IS NOT NULL AND org_key(f) = org_key(c)
  0         otherwise   (incl. user-authored candidate where created_by is a user)
```

Folded into the existing combined score (weights are starting points, tuned via
the `_explain` eval harness; `sem` stays dominant):

```
combined = 0.50·sem + 0.30·con + 0.12·grp + origin − 0.30·neg
           with EXACT_W ≈ 0.18, ORG_W ≈ 0.09
```

(`con` drops 0.35→0.30, `grp` 0.15→0.12 to make room; net change is small and
eval-validated.) The `>= 0.15` acceptance threshold and the facet gate
(`thread_facets_gated`) are unchanged — origin rides *inside* the score, so it
strengthens a focus that the user has trained without overriding the structural
stages or the facet gate.

### Resolving the origin keys

`classify_thread_for_user_explain` currently loads the candidate's
embedding/topic/contacts/groups/facets/author_id. Add:

- **Candidate connection** `c` = `thread.created_by` **when it references a
  `twist_instance`** (connector thread); NULL when it's a user (user-authored
  thread → no origin signal, term is 0).
- **Example connections** `f` = `created_by` of each `user_moved` thread in the
  `moved` CTE (join `thread` is already there; just select `created_by`).
- **`org_key(twist_instance_id)`** — a `STABLE` SQL helper:
  - `domain:<account_domain>` when `account_domain` is set **and not freemail**
    (`public.domain.freemail`),
  - else `team:<team_id>` when `team_id` is set,
  - else `NULL`.

Distinguishing whether `created_by` is a `twist_instance` vs a `user`: prefer a
direct existence check against `twist_instance` (or reuse whatever predicate the
codebase already uses to tell connector threads apart — verify during planning).

### The one connection-time change: `twist_instance.account_domain`

The connected account's email/domain is **not stored queryably today** — only in
`account_label` (a display string) and encrypted tokens. Add a nullable,
lowercased `twist_instance.account_domain text`, populated at auth from the
OAuth account info we already use to set `account_label`
(`workers/api/src/twist/management.ts` ~925–931, and the
`/sync/twist-instances` upsert). Email connectors → the email's domain; other
connectors → a workspace domain when the provider exposes one, else NULL.

- Additive, nullable, server-only (not synced to Flutter). No backfill — existing
  connections get NULL until re-auth, and the signal degrades gracefully (NULL
  domain → L2 falls back to `team_id`, then to L1-only).
- **Planning must first check** whether `twist_instance_connection.actor_id →
  contact.email` already yields the account domain live; if it does reliably, we
  can skip the new column entirely and resolve `org_key` from the existing
  actor→contact→email path. The column is the fallback if that path is unreliable.

`public.domain.freemail` already exists (from the facet work) and is seeded with
~102 providers; reuse it to classify domain as personal vs org.

### Cold start: seed from focus-creation picks, keep the picker diverse

Cold start is handled by **seeding affinity at focus creation**, not by a prior:

- The threads the user keeps in the find-matching-threads preview when creating a
  focus must be filed as `user_moved` so their origins seed L1/L2 on day one.
  Today the create endpoint (`POST /sync/priorities`) only upserts the priority;
  the client issues separate moves. **Verify** the client files the kept threads
  via `/sync/priority-moves` (which sets `user_moved = TRUE`), or have the create
  flow file selected `thread_ids` as `user_moved` directly. This is the load-
  bearing cold-start mechanism — "Acme admin" created by picking a few work
  threads routes the next work receipt immediately.

- **The picker must stay origin-diverse and must NOT pre-bias ranking by
  origin.** An *incorrect* early origin bias is worse than none: it would surface
  only one origin's threads, leaving the user able to deselect but never discover
  the right ones. We may *label/group* preview candidates by origin so the user
  can grab the right cluster quickly, but we never hide or down-rank the others.
  (No change to find-matching-threads ranking in v1; this is a constraint, not a
  feature.)

### Learning from reclassifications — free

Reclassification already updates the exact signals origin rides on: a move out of
`F` writes a `thread_priority_negative`, a move into `G` writes a `user_moved`
positive. So both focuses' origin affinity self-corrects with no new code.
(Optionally, a future enhancement could add an origin penalty term keyed on
`thread_priority_negative`; not in v1.)

## Components changed

| Component | Change |
| --- | --- |
| `libs/db/schema/50-tables/95-twist_instance.sql` | add `account_domain text` (nullable, lowercased), server-only |
| `libs/db/schema/60-functions/` | new `org_key(twist_instance_id)` `STABLE` helper |
| `libs/db/schema/60-functions/classify_thread_for_user.sql` | load candidate `created_by`; select `created_by` in `moved` CTE; add per-pair `origin` term + weights into `combined`; expose `origin` in `_explain` scores jsonb |
| `workers/api/src/twist/management.ts` (+ `/sync/twist-instances`) | populate `account_domain` from OAuth account info at auth (unless actor→contact path suffices) |
| Focus-creation flow | ensure kept preview threads are filed `user_moved` (verify client; may be no-op) |
| find-matching-threads picker | constraint: stay origin-diverse, no origin pre-bias (optional: group/label by origin) |
| pgTAP | exact-match boost, org-group transfer (work-Gmail↔work-Slack), no-merge for two freemail accounts, user-authored candidate = 0, NULL-domain graceful fallback, cross-categorization still routable after a move |

## Rollout

Going-forward only. New migration is additive/expand (nullable column + new
function + `CREATE OR REPLACE` on the classifier). No Flutter change.
`account_domain` populates as connections re-auth; until then L2 falls back to
`team_id`/L1, so behavior only ever improves.

## Open questions for planning

1. Confirm `actor_id → contact.email` cannot reliably supply the account domain
   before committing to the `account_domain` column.
2. Confirm the predicate for "`created_by` is a `twist_instance` vs a user".
3. Confirm focus-creation kept-threads are filed `user_moved` end to end.
4. Tune `EXACT_W` / `ORG_W` and the `con`/`grp` rebalance against the eval
   harness before locking weights.
