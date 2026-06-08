# Thread Facet Classification — Design

**Date:** 2026-06-08
**Status:** Approved design, pending implementation plan
**Scope:** Backend only. No Flutter / UI changes, now or planned. Facets are
internal classifier signal, not user-facing search facets.

## 1. Problem

Thread auto-classification (`classify_thread_for_user`) and focus-creation
matching (`POST /sync/priorities/find-matching-threads`) currently score threads
against a focus using **content** (embedding), **contacts**, and **groups**
only. They have no notion of the *kind* of a message or the *relationship* of
its sender. Two concrete failures:

1. A **Reading** focus (newsletters, long-form) also collects unrelated items
   with similar content — app notifications, marketing blasts — because they
   match on content.
2. Classification is poor at separating messages from **high-importance
   contacts** from **unsolicited** messages.

Both are *format* / *sender-type* problems that content similarity cannot solve.

## 2. Approach

Add two layers:

- **(A) Facet extraction** — distill each thread into a small set of queryable
  attributes (facets). Heuristics only; no per-thread LLM cost. Computed at the
  source (connectors), communicated through a first-class SDK interface.
- **(B) Per-focus facet filters** — at focus create/update, an LLM configures
  filters (include/exclude per dimension) stored on the focus. The classifier
  enforces them as a **hard gate in the scoring stage**, with learned per-sender
  exceptions so user overrides generalize.

Design priorities: deterministic & cheap extraction; extensible facet set
(add/refine over time without migrations); imperfect-heuristic safety
(fail-open, user moves always win).

## 3. Facet taxonomy

Facets are split into **orthogonal dimensions** so filters compose. A newsletter
is long-form *and* sent to a list *and* automated — three independent facts.

### Intrinsic facets (message-derived; connector-emitted; stored on the thread; same for every viewer)

| Dimension | Values | Notes |
|---|---|---|
| `format` | `chat`, `message`, `reading`, `notification`, `receipt`, `invoice`, `promotion` | Single-valued. `promotion` (marketing) is distinct from `reading` and is a major polluter of Reading focuses. **Nullable** — non-communication sources leave it null. |
| `automation` | `human`, `automated` | Orthogonal to format. A person can send an invoice; a bot sends a notification. Drives "people-only" focuses. |
| `reach` | `direct`, `list` | `list` = List-Id / List-Unsubscribe present, or high recipient count. |

Format value sketch:
- `chat` — short, conversational (Slack DM/quick message)
- `message` — substantive personal/business correspondence
- `reading` — long-form meant to be read (newsletters, articles, digests)
- `notification` — transactional/system notification
- `receipt` — purchase/order/payment confirmation
- `invoice` — bill / payment request / statement
- `promotion` — marketing/promotional blast

### Relationship (NOT a stored facet — a focus filter mode evaluated live, per-user)

`relationship` is recipient-relative (is this sender known to *me*?), so it
cannot be a thread-level stored value. It is **not materialized**. Instead it is
a focus filter mode (`trustedSendersOnly`) evaluated live at classification time
(see §6). A sender is **trusted for focus F** when either:
- **Per-focus engagement** — the sender participates in a thread filed in `F`
  that the user explicitly placed there (`thread_priority.user_moved = TRUE` OR
  `thread.created_by = U`), or
- **Org-domain match** — the sender's email domain is one of the user's own
  linked-identity domains, excluding freemail/public hosts.

Everyone else (including inbound-only senders the user has never engaged) is
untrusted. Inbound-only ≠ trust, by design.

### Extensibility

Each dimension is a registered facet with a controlled vocabulary, a
cardinality, and an owner (connector-emitted vs. server-derived). Adding a
dimension or value later does not require a storage migration (jsonb,
server-only). Recipe in §9.

## 4. SDK interface & storage

### SDK (`public/twister/src/facets.ts`, new — single source of truth)

Defines the vocabulary for all dimensions plus the connector-settable subset:

```ts
export type Format = 'chat' | 'message' | 'reading' | 'notification'
  | 'receipt' | 'invoice' | 'promotion';
export type Automation = 'human' | 'automated';
export type Reach = 'direct' | 'list';

// Connector-settable, intrinsic to the message. Nullable per Twister entity
// standards (| null, not optional, except the whole object is optional on NewLink).
export type ThreadFacets = {
  format: Format | null;
  automation: Automation | null;
  reach: Reach | null;
};
```

`relationship` is **not** part of `ThreadFacets` and is **not** expressed as an
include/exclude value set. In `priority.facet_filters` it is a single boolean,
`trustedSendersOnly`. The `self | trusted | untrusted` labels are conceptual —
they describe the live per-user evaluation (§6), not stored filter values.

`NewLink` gains `facets?: ThreadFacets`. A connector sets facets on the link it
saves via `integrations.saveLink`. Requires a changeset (`minor`) and a twister
rebuild. Update `public/twister/package.json` exports if a new top-level file is
added.

### Storage (server-only, never synced — pure classifier signal)

- `thread.facets jsonb` — e.g. `{"format":"reading","automation":"human","reach":"list"}`.
  Written at thread creation from the creating link's `facets`. **Not added to
  any `user.*` view** → no client sync, no Flutter change. Optional GIN /
  expression index decided at impl (mainly for the focus-creation scan).
- `priority.facet_filters jsonb` — per-dimension include/exclude sets the LLM
  writes, plus `trustedSendersOnly`. Example:
  ```json
  {
    "format": { "include": ["reading"], "exclude": ["notification","promotion","receipt","invoice"] },
    "automation": { "exclude": ["automated"] },
    "trustedSendersOnly": true
  }
  ```
  Dedicated column (cleaner than overloading the sparse `priority.config`).
- `priority.description text` — persist the NL description the focus-creation
  flow already produces. **Today this description is sent to
  `find-matching-threads` and then discarded — an oversight to fix.** The focus
  create/update path must now write it to `priority.description` so it survives
  for filter (re-)derivation and future use. No UI; backend-only.
- `freemail_domain` reference table — seeded from the existing list in
  `apps/site/app/routes/upgrade.tsx` (`FREEMAIL_DOMAINS`). SQL-side source of
  truth for the org-domain check. The site's TS copy is a future consolidation,
  not addressed here.

All thread/priority columns are additive nullable → a single expand migration,
backward-compatible. Old clients are unaffected (nothing synced).

## 5. Extraction (connector-side, shared heuristics)

### Shared package `@plotday/email-classifier` (new, in `public/connectors/`)

A pure, unit-testable `classifyEmail(signals: EmailSignals): ThreadFacets`.
`EmailSignals` is a normalized input the connector assembles from raw headers it
already has access to:
- `List-Id`, `List-Unsubscribe`, `Precedence`, `Auto-Submitted`,
  `X-Priority` / `Importance`, `Authentication-Results`, `Return-Path`
- from-address, to/cc counts, subject, isReply (In-Reply-To/References),
  body length, optional Gmail `CATEGORY_*` labels

Heuristic sketch (refined during impl, covered by fixtures):
- `reach=list` ← List-Id/List-Unsubscribe present or high recipient count
- `automation=automated` ← Precedence bulk/auto-reply, Auto-Submitted,
  no-reply localparts, DMARC "via" rewrite, bot senders
- `format=promotion` ← `CATEGORY_PROMOTIONS` / marketing patterns
- `format=reading` ← newsletter senders + long body + unsubscribe (editorial)
- `format=receipt` / `invoice` ← subject/body keywords + amounts
- `format=notification` ← automated + short + `CATEGORY_UPDATES`
- `format=message` ← default human email; `chat` for short interactive

**Safety principle:** set a facet only when a heuristic is confident; otherwise
leave it null. The gate never excludes on a null value.

### Per-connector wiring

- **Gmail** — collect headers + labels (already fetched), call `classifyEmail`,
  set `link.facets` before `saveLink`. Outlook-mail / apple-mail reuse the same
  package when they exist. (There is no Outlook *mail* connector today — only
  calendar.)
- **Slack** — compute facets directly (source-specific, small helper, no shared
  pkg): `automation=automated` if `bot_id`/`app_id`/bot subtype;
  `reach=direct` for DMs, `list` for channels; `format=chat` (long posts →
  `message`).
- **Single-kind connectors** (Linear, Calendar, Drive) — set only what's
  meaningful, or nothing. `format` null is fine and ungated.

## 6. Classifier integration

### Gate placement

The facet gate applies **only in the scoring stage** of
`classify_thread_for_user_explain` (stage 3) and in `find-matching-threads`.
Earlier stages — topic short-circuit, keyed-priority, channel-default — are
explicit/structural intent and remain **ungated**. Content-similarity false
positives (the motivating bugs) arise only in scoring, so that is the surgical
place to filter.

### Gate evaluation (per candidate thread `T` vs scored focus `F`)

Read `T`'s intrinsic facets from `thread.facets`; read `F.facet_filters`.
- **exclude** set on a dimension → `T`'s value ∈ exclude ⇒ **violation**.
- **include** set on a dimension → `T`'s value is *known* and ∉ include ⇒
  **violation**.
- **Fail-open on unknown:** a null value never violates an include filter. The
  gate only ever acts on a known fact.

A violating focus is dropped from the scored candidates before the `≥ 0.15`
winner is selected. If all candidates are gated out, classification falls
through to `priority_prefix` → `root_fallback` — the thread always lands
somewhere and is never lost.

### Unified per-focus trusted-sender predicate

One `EXISTS` powers both the gate exception and the trust filter:

> Contact `A` is **trusted for focus F** (for user `U`) when `A = ANY(x.contacts)`
> for some thread `x` filed in `F` where `tp.user_moved = TRUE OR x.created_by = U`.

Captures both explicit signals: recipients of threads the user *composed* into
the focus, and senders of threads the user *moved* into it. Auto-filed threads
do not count (no circular reinforcement).

- **Sender exception (format/automation/reach gate):** bypass the exclude-gate
  for `F` when `A` is trusted-for-`F`. (Move one Stripe receipt into Finances →
  every future Stripe receipt bypasses Finances' receipt-exclusion — for that
  focus, that sender only.) Org-domain does **not** bypass the format gate.
- **Trust filter (`trustedSendersOnly`):** admit `T` iff its author is
  trusted-for-`F` **OR** matches org-domain.

### Org-domain match (live, freemail-excluded)

`A`'s email domain (from `contact.email` of `T.author_id`) ∈ the user's own
identity domains (`user_contact.linked = true` → `contact.email` domains),
excluding any domain in `freemail_domain`. A STABLE SQL helper computes this.

### Performance

- `idx_thread_priority_priority_id` / `idx_thread_priority_user_moved` scope the
  predicate to a focus's filed threads; `idx_thread_contacts` (GIN) backs
  `A = ANY(contacts)`.
- Auto-classification: one author × ≤3 scored focuses.
- `find-matching-threads`: N candidate authors × the *single* focus being
  created.
- No `note`-table scans, no per-classification fan-out. No materialized trust
  state (no table, no `user_contact` bool, no triggers, no backfill).

**Documented fallback:** if per-focus cold-start proves too aggressive, add a
global engagement bool on `user_contact` (set by triggers on user authoring,
backfilled from existing notes/threads). Not built now.

### Implementation shape

- Extend `classify_thread_for_user_explain`: the `scoring` CTE joins
  `priority.facet_filters`, applies the gate with the trusted-sender `NOT EXISTS`
  exception and the org-domain helper, then picks the `≥ 0.15` winner from the
  surviving candidates.
- Apply the same filter to the `find-matching-threads` candidate query.

## 7. LLM focus-filter configuration

**One registry, two consumers.** A TS module mirroring SDK `facets.ts` defines
each dimension, its values, and a human-readable description of each value. Both
the LLM prompt and the gate read it, so the model's mental model and the
enforcement never drift. Adding a value updates the prompt automatically.

**When derived (new and updated focuses only — no backfill):**
- **Creation** — alongside `find-matching-threads` (description in hand), derive
  filters and persist to `priority.facet_filters`.
- **Update** — on title/`description` change, re-derive in a background task
  (`waitUntil`, fresh DB connection per the project's `waitUntil` rule).

Existing focuses are **not** backfilled: with no `facet_filters` they classify
exactly as today (no gate). Filters appear the next time the focus is edited.

**How:** Claude via the AI gateway, reusing the `generateObject` + zod + retry +
ephemeral-cache pattern in `priority-match.ts`. Input = title + description +
registry value descriptions. Output = validated `facet_filters`.

**Conservative by construction:** the prompt constrains a dimension only when the
focus clearly implies it; otherwise leave it unconstrained (no gate on that
axis). Over-gating is the main risk → default to "don't filter." LLM unavailable
⇒ no filters written ⇒ focus classifies exactly as today (fail-open). New catch
blocks call `captureException`.

## 8. Rollout & testing

**Migrations (all additive expand, backward-compatible):** `thread.facets`,
`priority.facet_filters`, `priority.description`, `freemail_domain` (+ seed).
Regenerate and commit `libs/db/src/types.ts`.

**Rollout — going-forward only:** facets populate on newly-synced threads;
filters are configured on focuses created or edited after launch. No backfill of
either thread facets (raw signals are gone) or existing-focus filters. Nothing
synced → no client impact.

**Tests:**
- `@plotday/email-classifier` — pure unit tests over header fixtures (vitest).
- Slack facet helper — unit tests.
- Classifier gate — **pgTAP** on `classify_thread_for_user_explain`: exclude-gate
  fires; include fail-open on null; sender-exception bypass via *both*
  `user_moved` and `created_by=U`; org-domain admit + freemail exclusion;
  all-gated → `root_fallback`.
- `find-matching-threads` filtering — TS↔PG harness (the `email-digest`
  rollback-txn pattern).
- LLM derivation — schema validation + mocked-prompt assertions.

## 9. Defense-in-depth recap (why imperfect heuristics are safe)

1. Gate runs only in the weakest-intent stage (scoring); topic/keyed/channel and
   explicit user moves always win.
2. Include-filters fail open on unknown facets.
3. Per-sender exceptions let user moves/compositions override the gate for
   similar future cases.
4. A fully-gated thread still routes to root — never disappears.
5. LLM filter derivation is conservative and fail-open.

## 10. Extensibility recipe (adding a facet)

1. Add the value to SDK `public/twister/src/facets.ts` (+ changeset, rebuild).
2. Extend the relevant extractor (shared email pkg or a connector helper).
3. Add the value's description to the classifier registry module.
4. Add gate handling if it needs new semantics (most reuse include/exclude).
5. Add pgTAP / unit coverage.

Storage and sync need no change — facets are jsonb and server-only.

## 11. Public submodule work (separate PRs + changesets)

- twister — `facets.ts` + `NewLink.facets` (+ changeset).
- `@plotday/email-classifier` — new shared package.
- gmail connector — assemble `EmailSignals`, set `link.facets`.
- slack connector — source-specific facet helper, set `link.facets`.

## 12. Finalize checklist

- `pnpm lint` in changed packages.
- Backward-compat: all columns nullable; nothing synced; old clients unaffected.
- `captureException` in all new catch blocks (TS) — none expected in SQL.
- `docs/updates.md`: brief user-facing line ("Focuses now sort by the *kind* of
  message and who it's from, not just the topic").
- `docs/features.md`: note smarter focus classification.
- Submodule changesets per the Twister rules.

## 13. Open implementation questions (resolve in the plan, not blocking design)

- Exact GIN/expression index on `thread.facets` (only if the `find-matching-threads`
  scan needs it).
- Where the priority create/update hook lives for filter derivation (locate the
  priority upsert path; run derivation in `waitUntil`).
- `facets` versioning marker for future re-extraction (nice-to-have).
