# Eval-framework workstream report

**Date:** 2026-06-11
**Spec:** `docs/superpowers/specs/2026-06-11-eval-framework-design.md`
**Plan:** `docs/superpowers/plans/2026-06-11-eval-framework.md`
**Branch:** `eval-framework` (merged to local main; never pushed)
**Operating manual:** `libs/eval/AGENTS.md` (the runbook for the next optimizing agent)

## TL;DR

All ten deliverables (A–J) shipped. The corpus format now expresses every
signal the production classifier consumes, three new ground-truth channels
exist (move-holdout, decision-log mining, LLM-proposed labels), the runner
replays time, and the report tells signal from noise. The first tuning pass
found one promising change (widened topic-ambiguity candidate lists + raised
LLM gating floors: kris 47.5% → 53.75% gold, +5 fixed / 0 broke) that does
NOT clear the pre-registered significance bar (pooled p = 0.0625) and was
flat on the untouched holdout — **proposed with reservations, production
defaults unchanged**. Two structural findings matter more than any constant:
(1) ~18% of the old corpus's labeled accuracy was a measurement artifact
(cases leaking into their own training set — now guarded), and (2) on real
data the deterministic ranking parameters have almost no leverage; quality
lives in the LLM stages and their gating.

## What shipped (per deliverable)

**A. Corpus schema v2** — connections (twist_instance + actor + team, org-key
faithful), facets + per-priority `facet_filters`/`description`, negatives
(`thread_priority_negative` mirror), subscription tier, timestamps
(`created_at`/`moved_at`/`as_of`), case `tags`/`gold_source`/
`source_thread_id`, embeddings split to `embeddings.yaml` with provenance
(`thread-title`/`note-content`/`local-title`). v1 corpora still load
byte-identically (frozen-fixture regression gate in CI-style vitest +
a zero-cache-miss LLM gate run at refactor time).

**B. Shape-preserving anonymization** — deterministic realistic fake names
(200×200 pools), freemail domains map into a real-freemail pool (DB freemail
seed still classifies them), org domains map to stable fake org domains
(equality preserved → org keys survive), emails coherent with names, topics
rewritten (emails inside `channel:` topics), group names scrubbed of contact
tokens, team/twist names synthesized, colliding fake emails deduped by
plus-addressing (a real `contact_email_unique` violation surfaced this).
Enforced `leakCheck` at the single write choke point: multi-token name /
email / boundary-matched domain hits outside title scope **block the
write**; title-scope and single-token hits become an audit list.

**C. Seeders** — `from-prod` v2 with refresh-preserving-labels (all 80 kris
cases re-hydrated via `source_thread_id` + title-disambiguated uuidv7-prefix
fallback; labels byte-preserved; corpus-wide slug migration including
hand-maintained training files; stale labels referencing archived priorities
nulled with notes), `--holdout-recent-moves`, `--timeline-cases`,
`--list-active-users` (no emails), draft threads excluded;
`from-decision-log` mining (latest-move-wins; graceful on absent table —
verified against prod: "absent, nothing to mine"); `add-prod-*` migrated to
the same leak-checked pipeline; the two legacy ungated `backfill-*` scripts
deleted.

**D. Embedding backfill** — local `Xenova/bge-small-en-v1.5` via
`@huggingface/transformers`. **Empirical finding: Workers AI mean-pools**
(CLS gave cosines 0.93–0.97 vs prod vectors; mean pooling gives
0.999999–1.000000). Parity gate PASSED at 1.000000; kris's 2 remaining null
embeddings filled; synthetics embedded uniformly locally (`embl-` refs).

**E. Time-replay backtest** — `--backtest` replays cases chronologically
with the training set restricted to moves before each case's `as_of`
(negatives on their own clocks); cold-start trajectory table bucketed by
training-set size. Verified on kris and all synthetics.

**F. CLI + honest statistics** — `--params`/`--base` ad-hoc variants
(typo-rejecting deep merge), `--sweep` grids (weights renormalization,
parse-time validation) with a leaderboard (Wilson CIs, paired McNemar vs
base, `~noise` flags, live-token costs), `--save-baseline`/`--baseline`
(fixed/broke/changed-neutral), rank-of-gold + MRR, per-tag and
per-gold_source slices, live-vs-replayed token accounting with cost
estimates, eval-side unlimited LLM budget (sweeps can't silently degrade),
holdout-move cases excluded from every run unless `--include-holdout`.

**G. Synthetic corpora** — `synthetic-newsletter-flood` (facet gate:
14/15 cases show `facetGated` activity; trusted-sender bypass + fail-open
controls), `synthetic-two-hats` (origin exact/org confirmed firing at
0.18/0.09 in explains), `synthetic-groups` (tie-breaker pressure, topic
ambiguity; two deliberately-hard LLM-stage cases). Labels by construction.

**H. Gold completion** — `propose-gold` labeled all 26 unlabeled kris cases
(`gold_source: llm-proposed`, `[llm]`-prefixed rationales, own prompt-id +
cache namespace). Audit table below. Reports slice by gold_source: on the
LLM cascade, human-gold 53.7% vs llm-proposed 34.6% — the circularity risk
is visible, not hidden.

**I. Runbook + hygiene** — `libs/eval/AGENTS.md` (quick start, corpus model,
run modes, statistics guardrails, cache-honesty table, seeding rituals,
privacy policy, corpora inventory, troubleshooting); README fixed;
`corpora/kris/baseline-report.md` regenerated (was 30-case/sql-only stale).

**J. First tuning pass** — below.

## Corpus inventory

| Corpus | Kind | Trainings | Cases | Gold | gold_source | Role |
| --- | --- | --- | --- | --- | --- | --- |
| kris | prod-extract | 199 (`full`) | 80 + 12 holdout | 92/92 | 54 human + 26 llm-proposed + 12 human (holdout) | primary tuning |
| prod-u2 | prod-extract | 103 | 47 + 10 holdout | 10 (holdout only) | human | **FINAL HOLDOUT — do not run** |
| prod-u3 | prod-extract | 24 | 55 + 6 holdout | 6 (holdout only) | human | tuning |
| synthetic-newsletter-flood | handcrafted | 20 | 15 | 15/15 | human (by construction) | facet-gate guardrail |
| synthetic-two-hats | handcrafted | 22 | 15 | 15/15 | human | origin/account guardrail |
| synthetic-groups | handcrafted | 19 | 15 | 15/15 | human | tie-breaker/topic guardrail |
| synthetic-tiny | handcrafted | 5 | 5 | 5/5 | human | loader fixture |

## The leakage correction (read this before comparing to old numbers)

18 of 80 v1 kris cases had their own thread in the training set (the thread
was later `user_moved`); they scored sem≈1.0 against their own copy. The
always-on self-exclusion guard archives a case's own training copy inside
the case savepoint. Honest baselines after the guard: the old "58.3% gold"
LLM number was really **43.3%**; 9 gold labels were "correct" only via the
leak. All numbers below are post-guard, on the v2 corpus.

## Baselines (v2 kris corpus, `full` training set, holdout excluded)

| Classifier | Gold acc [95% CI] | Notes |
| --- | --- | --- |
| `ts:hybrid:default` (deterministic) | 20.0% [12.7–30.0] | 60/80 cases decided by non-ranking stages |
| `ts:hybrid-llm:default` (production config) | 47.5% [36.9–58.3] | ±1 case run-to-run jitter from neighbor-order ties |
| `ts:hybrid-llm:tuned-2026-06` (C2) | 53.75% [42.9–64.2] | +5 fixed / 0 broke vs default |

Stage-level (LLM cascade): `llm_topic_ambiguity` 42 cases @ 42.9% (the
dominant miss bucket), `llm_tiebreaker` 26 @ 61.5%, `llm_channel_default`
4 @ 25%, `priority_title_override` 5 @ 60%.

## Tuning pass

### Pre-registration (verbatim, written before any holdout run)

Candidates: **C2 (primary)** = `llm.topicAmbiguity.maxTopicCandidates 4→6`,
`maxScoringCandidates 3→5`, `highConfidenceFloor 0.6→0.75`,
`marginFloor 0.2→0.3`. **C1 (fallback)** = topicAmbiguity widening only.
Decision rule: evaluate C2 once on the holdout; do not propose if it breaks
≥2 more holdout cases than it fixes; otherwise propose with the honest
caveat that tuning-surface p = 0.0625 is short of the noise bar.

### Tuning-surface evidence

| Surface | default | C2 | paired |
| --- | --- | --- | --- |
| kris (80) | 47.5% (38/80) | 53.75% (43/80) | +5 / 0 |
| prod-u3 (6 gold) | 50% (3/6) | 50% (3/6) | 0 / 0 |
| synthetic-groups (guardrail) | 86.7% (13/15) | 93.3% (14/15) | +1 / 0 |
| synthetic-newsletter-flood (guardrail) | 93.3% (14/15) | 93.3% (14/15) | 0 / 0 |

Pooled real-data McNemar: 5–0 discordant, **p = 0.0625** (α = 0.05 not met).

### Holdout (evaluated exactly once, after pre-registration)

| Holdout | default | C2 | paired |
| --- | --- | --- | --- |
| kris `holdout-move` (12) | 3/12 | 3/12 | 0 / 0 |
| prod-u2 (10 gold) | 4/10 | 4/10 | 2 fixed / 2 broke |

Flat (n = 22 — a directional sanity check, as pre-registered; it neither
confirms nor refutes). prod-u2 expected-accuracy moved 38.6% → 40.4%
(uninformative; expected = the old prod classifier's own choices).

### Outcome and PROPOSED diff (not applied)

Per the pre-registered rule, C2 is **proposed with reservations**. The
production diff, if Kris adopts it (`libs/classifier/src/ts-hybrid.defaults.ts`):

```diff
 export const DEFAULTS: HybridParams = {
   ...
-  highConfidenceFloor: 0.6,
-  marginFloor: 0.2,
+  highConfidenceFloor: 0.75,   // more scoring cases get the LLM sanity check
+  marginFloor: 0.3,
   ...
 };
 export const DEFAULTS_LLM: HybridParams = {
   ...
     topicAmbiguity: {
       enabled: true,
-      maxTopicCandidates: 4,
-      maxScoringCandidates: 3,
+      maxTopicCandidates: 6,    // the dominant miss bucket sees more options
+      maxScoringCandidates: 5,
       promptId: "topic-ambiguity-v3",
     },
   ...
 };
```

Evidence for: +5/0 on kris, +1/0 on groups, zero observed breakage anywhere
on the tuning surface; the change only widens LLM option lists and gating
(cost: ~+10% topic-ambiguity prompt tokens, no new calls; floors add ~1–2
LLM calls per 80 classifications). Evidence against: p = 0.0625; holdout
flat with 2/2 churn on prod-u2. **Recommendation: hold until decision-log
mining (live after the predecessor workstream deploys) grows the labeled
set, then re-test C2 against the mined corrections — the runbook documents
the exact procedure.** The variant is registered as
`ts:hybrid-llm:tuned-2026-06` for continued study.

### Negative results worth keeping (saved future effort)

- **Deterministic ranking params have no leverage on real data**: weights,
  aggregation k, account-hierarchy, title-match, score threshold — all
  within ±2 cases on kris (most exactly 0 flips). Structural stages decide
  60/80 cases; scoring-stage misses are mostly cold-start-shaped.
- **`originBonus` is accuracy-inert everywhere** (kris: one connection
  dominates, so the bonus is rank-preserving; two-hats: the author signal
  already encodes same-connection identity — `created_by` IS the
  twist_instance). The org branch is its only non-redundant surface, and it
  fires correctly (0.09 in explains) without changing outcomes. Leave the
  SQL-derived defaults; do not spend more tuning effort here.
- **Lowering LLM gating floors breaks badly** (0–9 fixed/broke, p = 0.004):
  the "send virtually every scoring case to the LLM" posture is right.
- **Tiebreaker maxCandidates 5→7: inert.**

### Exploration accounting

≈40 comparisons explored (7 deterministic dims × kris/two-hats, 3×3 + 2 LLM
floor grids, 2×2 topic-ambiguity, tiebreaker pair). Two candidates
pre-registered; one holdout evaluation total.

## LLM-proposed gold labels awaiting audit (26)

`propose-gold` audit table (also reproducible: labels carry
`gold_source: llm-proposed` and `[llm]` rationales in
`corpora/kris/cases.yaml`):

006→kids, 009→talentlift, 013→plot-user-success, 014→plot-user-success,
016→connector-testing, 025→product, 029→plot-user-success, 056→marketing,
057→marketing, 059→testing, 060→marketing, 061→plot, 062→marketing,
063→plot-user-success, 064→plot, 065→marketing, 067→content, 068→content,
069→product, 070→content, 072→marketing, 078→finance-admin, 080→talentlift,
083→plot, 084→income, 085→hr-committee.

To audit: edit `gold`/`gold_rationale` and set `gold_source: human` (or
delete `gold_source` — absent + gold ⇒ human). The 6 stale-nulled cases
(priorities archived in prod, e.g. the old "Using Plot") were re-labeled by
the same run; their notes carry the old label for reference.

## Anonymization spot-check requests for Kris

- Leak-check **warnings** (title-scope + single-token hits) are audit-grade
  by policy: thread/priority titles are verbatim, and several of your
  contacts are service-named ("Plot", "Linear", "Cycling Weekly"), whose
  tokens match benign YAML. A handful of your training-thread titles embed
  your own addresses, e.g. `… (EST) (kris@plot.day)` — own-data, policy-
  allowed, listed here for awareness.
- prod-u2/prod-u3 contain **zero raw identity** (verified: anonymized
  emails everywhere incl. READMEs, no note-content embedding vectors,
  heuristic scan shows only anonymizer-shaped addresses). Worth a 5-minute
  skim of `corpora/prod-u2/world.yaml` titles given titles stay verbatim —
  that is the one designed-in residual exposure (spec decision 3).
- `plot.day → briargrove.com` deterministically in every corpus (prod-u2's
  owner shares your org domain), so cross-corpus org grouping is preserved.

## Decisions made at forks (the load-bearing ones)

1. **Self-exclusion at the runner** (not only seeder discipline) after the
   adversarial spec review found mined/preserved cases would leak into
   training — this re-based every historical accuracy number (43.3% not
   58.3%).
2. **v2 models prod `created_by` semantics** (connection in `created_by`,
   contact in `author_id`); v1 corpora keep old semantics via
   `created_by_override` so the frozen regression gate stays byte-exact.
3. **Token-needle leak findings are audit-grade, full multi-token names are
   violations; name needles match word boundaries, domains left-boundary** —
   tuned against real extraction false-positive storms ("link" inside
   `linked_to_user`, fake `pebblebay.com` containing `ebay.com`).
4. **Tic-less connections keep their identity** via placeholder null-email
   actors (kris's main connections have no `twist_instance_connection` rows;
   dropping them would have killed every channel topic in the corpus).
5. **Mean pooling for local embeddings** — empirical parity against prod
   vectors, contradicting the BGE paper's CLS recommendation.
6. **Decision-log mining keeps only the final move** per thread (A→B→A
   mines nothing): a label the user later repudiated is not ground truth.
7. **Drafts excluded from extraction** (NULL titles; not classification
   candidates).
8. **prod-u4 skipped** — the fourth-most-active user has 4 moves; too thin.
9. **propose-gold restricted to kris** per spec H; prod-u2/u3 gold stays
   move-derived only.

## Costs

Live Gemini spend (whole workstream): ≈ 700 calls ≈ 730K input / 40K output
tokens ≈ **$0.32** at the estimate table. The LLM file cache
(`libs/eval/.cache/llm/`, gitignored) makes every repeated run free; the
zero-cache-miss gate and floor sweeps exploited this throughout.

## Follow-up commands (exact)

```bash
# Everyday eval (worktree DB port from .worktree-db; ambient env may be stale)
cd libs/eval && DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:<PORT>/postgres \
  pnpm exec tsx src/cli.ts --corpus kris --classifiers ts:hybrid-llm:default,ts:hybrid-llm:tuned-2026-06 --training-sets full

# After deploying the decision log to prod (predecessor workstream):
pnpm prod-db-connect   # then:
cd libs/eval && pnpm exec tsx src/seeder/from-decision-log.ts --corpus kris
# → mined user corrections become labeled cases; re-test C2:
DATABASE_URL=... pnpm exec tsx src/cli.ts --corpus kris --params <C2 overrides> --training-sets full

# Refresh kris (preserves labels byte-exact, re-extracts everything else)
pnpm exec tsx src/seeder/from-prod.ts --user-email kris@plot.day --out kris \
  --case-count 80 --holdout-recent-moves 12

# Audit LLM-proposed labels: edit corpora/kris/cases.yaml (see section above)
```

Full operating manual: `libs/eval/AGENTS.md`.

## Suite state

342 vitest tests green (`libs/eval`), `pnpm lint` clean in `libs/eval` and
`libs/classifier`; frozen v1 fixture gate byte-identical throughout; no
production schema, workers, or `public/` submodule changes anywhere in the
branch.
