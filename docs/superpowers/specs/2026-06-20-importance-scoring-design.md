# Importance Scoring Rework — Design

Date: 2026-06-20
Status: Approved (brainstorm) → ready for implementation plan
Branch context: `fix/reliability`

## Problem

`thread_state.importance` (smallint 0–100, default 50, per `(user_id, thread_id)`)
is the single knob that decides whether a thread reaches a user proactively. The
downstream rule is a hard binary gate: **`importance >= 50 OR urgent`**. Below
that (and not urgent) a thread sends **no push, no email digest, no priority
unread badge** — it only remains visible, ranked lower, in Catch Up.

Consumers of the gate / ordering:

- Push notification content — `workers/api/src/app/notification-content.ts:92`
- Push re-check — `workers/api/src/state/push-notify.ts:205`
- Email digest — `workers/api/src/state/email-digest-query.ts:66`
- Notify candidates — `workers/api/src/state/notify-candidates.ts:50`
- Priority unread badge — `libs/db/schema/90-user-schema/21-priority_unread.sql:57`
- Feed / Catch-Up ordering — `apps/plot/lib/state/priority.dart:1453`, `apps/plot/lib/store/thread.dart`

Importance is computed by an LLM, per-note, per-member, in
`workers/api/src/queue/note-analysis.ts` (`classifyNote`), using
`@cf/meta/llama-3.3-70b-instruct-fp8-fast`. It is enqueued for app notes
(`sync/notes.ts:449`) and connector channel notes (`queue/updates.ts:597`),
for recent (<7d), AI-enabled, in-quota notes. The same call also sets
`active` / `urgent` / `skip`.

### Prod evidence — the signal is effectively dead

Readonly prod DB, 2026-06-20:

- 86–97% of `thread_state` rows sit at exactly 50. For threads **created in the
  last 21 days** (isolating current AI behavior from the May `thread_state`
  migration backfill): **86.3% at 50, 11.2% at 60**, the rest a rounding error.
- **Only 26 rows in the entire production database score below 50; just 2 in the
  last 21 days** — despite the prompt instructing the model to score
  promotional/cold-outreach material 5–30, and despite **97% of recent threads
  (1118/1153) being connector mail**, exactly where suppression should fire.
- Every non-50 value is a multiple of 5, dominated by 50/60. The prompt's own
  JSON example shows `50`/`75`, which the model copies.
- Internal inconsistency: 11 recent threads are `active=true` but left at
  `importance=50` — the model won't even raise importance for things it flags
  actionable.

**Conclusion:** the continuous 0–100 scale has collapsed to a near-constant; the
low-importance suppression path (importance's reason for existing) essentially
never fires. The system fails *open* (notify) for everything — consistent with
the phantom-notification incidents in project memory.

### Predictiveness check (validates the engagement signal)

Among `(recipient, sender)` pairs with ≥5 threads over 120 days, read-rate is
bimodal: 36 pairs (248 threads) at <10% read (systematically ignored), 17 pairs
(765 threads) at >90%. Global read rate is 87.5%. The near-zero-read cohort is
real, un-suppressed noise the current scorer misses. Per-sender history is
predictive and worth building on.

## Root causes

1. **Numeric scoring is the wrong task shape.** A 70B model asked for a
   calibrated 0–100 float anchors on the default/example and refuses the low end.
2. **The scorer is blind to the predictive signals.** It sees text + display
   names only — not whether the sender is known, the recipient's engagement
   history, whether the mail is automated/list/bulk, or the channel.
3. **Fails open on every miss.** AI-disabled, quota, parse-fail, >7-day import
   all default to 50 → notify.

## Decisions (from brainstorm)

- **Scope:** A + B + C — reframe LLM output to an ordinal band; deterministic
  cold-sender context; per-`(channel,sender)` engagement history.
- **Suppression strength:** *Soft bias the LLM* — deterministic signals are
  context the model acts on; **no hard cap below the gate**; the LLM has final
  say. (Hard-cap-on-consensus held in reserve as the next lever if measurement
  shows the model still won't suppress.)
- **Engagement source:** on-demand, batch-cached SQL aggregate (no new table,
  no migration), mirroring `ts-hybrid-cache`.
- **Placement:** core/private. Importance scoring cannot run in a connector — it
  needs cross-connector per-recipient data, a privileged `thread_state` write,
  and is recipient-relative. It reads the **public** facets connectors already
  produce. No new public surface this pass.

### Why core (IP)

The classifier (`libs/classifier`, private) and the importance scorer
(`workers/api`, private) are already in core. The public seam is *signal
production + contract*: `@plotday/email-classifier` (`public/libs/email-classifier`,
header→facet) and the `ThreadFacets` type (`public/twister`). That split is
correct: public produces commodity signals against a shared contract; core fuses
them into intelligence. The moat — the fusion + behavioral feedback loop + the
user's data — is already private. Keeping the signal layer public is a
contributor on-ramp that costs no IP.

## Architecture

New focused unit `workers/api/src/state/importance/`, three small files with
clear seams. **One LLM call, not two** — `classifyNote` keeps its single call;
we enrich its prompt and change the `importance` field to an ordinal band.

### `engagement.ts`

```
getSenderEngagement(db, recipientUserId, senderContactId, cache)
  → { priorThreads, readRate, archivedUnreadRate, replyRate }
```

One scoped, indexed SQL aggregate over the recipient's prior threads from that
sender (~120-day window, excludes the current thread). Batch-memoized per
`(userId, senderContactId)` using the `ts-hybrid-cache` pattern. Below a minimum
history (<3 threads) returns nulls → "insufficient history". Best-effort:
degrades to nulls on failure, `captureException` only on unexpected errors.

Sender identity keys on `thread.author_id` (a contact id) for v1. Author-id
churn (see project memory: mute breakage on contact-id change) only *splits*
history here — it degrades gracefully, it is not a correctness bug. Keying on a
more stable identity is a possible refinement, not required.

### `features.ts`

```
gatherImportanceFeatures(...) → ImportanceFeatures (+ a compact prompt block)
```

`ImportanceFeatures`:

| Field | Source | New? |
|---|---|---|
| `facets` = `{ automation, reach, format }` \| null | `thread.facets` (public email-classifier) | reads existing, unused |
| `senderEmailAutomated` (no-reply / notifications@ pattern) | `contact.email` | — |
| `senderIsLinkedUser` (real person vs synthetic source) | `user_contact.linked` | — |
| `senderKnown` / `priorThreads` | engagement | 🆕 |
| `readRate` / `archivedUnreadRate` / `replyRate` | engagement | 🆕 |

Engagement is per-recipient; gathered per member (members lists are small;
batch-cached). Facets are thread-level. `ImportanceFeatures` is the single seam
between deterministic gathering and the LLM.

### `band.ts` (pure — no DB, no LLM)

- `ImportanceBand = "suppress" | "low" | "normal" | "elevated"`
- The rubric prompt fragment.
- `bandToImportance(band)`:

| Band | importance | vs gate (≥50) |
|---|---|---|
| suppress | 15 | below — no push/email/badge |
| low | 45 | below — no push/email/badge |
| normal | 60 | above — surfaces (new default) |
| elevated | 85 | above — surfaces, sorts high |

## The prompt reframe (in `classifyNote`)

Replace the numeric `importance` field and its `50`/`75` example with the
ordinal band. Inject the feature block. Rubric:

- **suppress** — promotional / mass-distribution / automated bulk the recipient
  consistently ignores. Signals: `automation=automated` AND `reach=list`; or
  historical `readRate < ~0.15` over ≥4 threads; or no-reply sender with no
  prior engagement.
- **low** — automated/FYI mail that isn't junk but needs no proactive surfacing.
- **normal** — ordinary correspondence the recipient would want surfaced (new
  default, replacing reflexive 50).
- **elevated** — personal/direct messages from known contacts, direct asks,
  time-sensitive. Signals: high `readRate`/`replyRate`, `reach=direct`, known
  sender.
- Guardrail kept: anything `urgent` or `active` must be ≥ **normal**.

JSON example switches to `{"importance": "normal"}` (no numeric anchor).
`parseClassification` / `parseClassificationOverride` parse the ordinal and map
via `bandToImportance`; unknown/missing → fallback below.

## Deterministic fallback (reliability, no hard cap)

When the LLM produces no usable band (AI-disabled, quota, parse-fail), derive a
fallback band from features rather than defaulting to 50:

- `automation=automated` AND `reach=list` (or no-reply sender with no history)
  → **low** (< gate, no notify)
- otherwise → **normal** (surfaces)

This is not overriding the LLM (it produced nothing) — obvious bulk mail stops
notifying even on the failure path, while real mail still defaults to surfacing.

## Error handling

- `thread.facets` missing (non-Gmail / older threads) → `facets = null`; lean on
  content + engagement. Expected.
- Engagement failure → nulls; `captureException` only for unexpected errors.
- LLM failure / parse-fail / AI-disabled → deterministic fallback band.
- `getSenderEngagement` runs inside the queue handler with the request-scoped
  `db` (same lifecycle as today's `gatherContext`) — no `waitUntil` /
  destroyed-connection concern.

## Testing (TDD)

- `band.ts` — pure: band→number; rubric renders; guardrail (urgent/active ⇒ ≥
  normal). No DB, no LLM.
- `engagement.ts` — integration vs test DB: seeded read/archive/reply history →
  expected rates; <3 threads → nulls; batch cache memoizes.
- `features.ts` — seeded `thread.facets` + no-reply sender → feature extraction +
  prompt block.
- `note-analysis` integration (mock AI):
  - ordinal band → correct mapped importance written;
  - promotional facets + low readRate + `suppress` → importance < 50 (absent in
    prod today);
  - LLM failure + `automation=automated`+`reach=list` → fallback `low` (< 50);
  - **regression:** existing `active`/`urgent`/`skip` and the unread-marking
    contract (`p_set_read_at`, `markThreadUnreadForOthers` fallback) unchanged.

## Scope

**In:** the importance module, prompt reframe, engagement signal, deterministic
fallback, reading existing facets. Server-only. **No schema/migration. No
public/submodule change.**

**Out (each its own spec):**

- **Feedback loop (E)** — learn from the user's own manual importance changes /
  mutes / archive-without-read as a prior.
- **Eval harness (G)** — offline measurement using real engagement as labels, to
  tune the band map and rubric.
- **Advisory connector hint** — optional public facet for connectors to elevate
  (the IP-safe public addition, deferred).
- **Precomputed engagement table** — only if the on-demand aggregate is a cost
  hotspot.

## Success criteria

Re-run the prod importance distribution post-deploy: the dead `<50` band should
become a real share of connector mail (the low-read-rate cohort) instead of
today's 2 rows in 21 days — without suppressing known-contact / direct mail.
