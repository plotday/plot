# Eval-framework workstream report

**Date:** 2026-06-11 (in progress — pre-registration section written before holdout evaluation per protocol)
**Spec:** `docs/superpowers/specs/2026-06-11-eval-framework-design.md`
**Plan:** `docs/superpowers/plans/2026-06-11-eval-framework.md`

## Tuning pass — PRE-REGISTRATION (written before any holdout run)

Recorded at the moment the tuning surface was frozen. The holdout (kris's 12
`holdout-move` cases + the entire `prod-u2` corpus, 10 gold cases) has not
been evaluated by any variant at this point.

### Candidates (≤3, per spec J.4b)

1. **C2 (primary)** — overrides onto `DEFAULTS_LLM`:
   `llm.topicAmbiguity.maxTopicCandidates: 4 → 6`,
   `llm.topicAmbiguity.maxScoringCandidates: 3 → 5`,
   `highConfidenceFloor: 0.6 → 0.75`, `marginFloor: 0.2 → 0.3`.
   Ad-hoc variant name on the tuning surface: `ts:hybrid-llm:default+params@65562df3`.
2. **C1 (fallback)** — topicAmbiguity widening only (6/5), floors unchanged.
   `ts:hybrid-llm:default+params@b924fa26`.

No third candidate.

### Tuning-surface evidence (holdout untouched)

| Surface | base (`ts:hybrid-llm:default`) | C2 | paired |
| --- | --- | --- | --- |
| kris (80 cases, holdout excluded) | 47.5% (38/80) | 53.75% (43/80) | +5 fixed / 0 broke |
| prod-u3 (6 gold tuning cases) | 50% (3/6) | 50% (3/6) | 0 / 0 |
| synthetic-groups (guardrail) | 86.7% (13/15) | 93.3% (14/15) | +1 / 0 |
| synthetic-newsletter-flood (guardrail) | 93.3% (14/15) | 93.3% (14/15) | 0 / 0 |

Pooled REAL-data paired McNemar (kris + prod-u3): discordant 5–0,
p = 0.0625 — **does not clear α = 0.05**. Synthetics are not pooled
(policy). C1 alone: 4–0 on kris (p = 0.125).

### Decision rule (committed now)

Evaluate C2 once on the holdout (kris `--include-holdout`, reading the
holdout-move tag slice; full prod-u2 run) alongside the default for the
paired comparison. The holdout is a **directional sanity check** (n = 22):
- If C2 breaks ≥2 more holdout cases than it fixes → do not propose.
- Otherwise → propose the C2 diff to Kris with the honest caveat that the
  pooled tuning-surface evidence is directionally clean (5–0) but p = 0.0625,
  short of the noise bar; final adoption is Kris's call, ideally after
  decision-log mining grows the labeled set.

### Exploration accounting (multiplicity context)

Deterministic sweeps run (all ~zero effect, all `~noise`): originBonus.exact
(7 points, kris + two-hats), originBonus.org (4 points, two-hats),
weights.sem (5), aggregation.k (4), accountHierarchyBonusWeight (5),
priorityTitleMatchWeight (4), scoreThreshold (4). LLM sweeps: floors 3×3
grid (lowering floors → 0–9 BROKE, p = 0.004 — wide-LLM gating is strongly
justified), floors-up 2 points (+1/0), topicAmbiguity 2×2 (the C1/C2 source),
tieBreaker.maxCandidates 2 points (inert). ≈ 40 comparisons explored in
total; only the pre-registered two reached the holdout stage.

(Remainder of the report is written after the holdout evaluation.)
