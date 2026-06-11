# Corpus: prod-u3

Anonymized snapshot of `c-fe8486093b47@yahoo.com` extracted on 2026-06-11 (corpus schema v2).

World: 21 priorities, 914 contacts, 2 groups, 5 connections, 30 channels, 1 teams, 85 embeddings (in embeddings.yaml).

Training sets: trainings/full.yaml holds 24 user_moved=TRUE threads, 0 negative-evidence threads, and 0 thread_priority_negative rows pulled from prod. Other files under trainings/ are maintained by hand and only get slug rewrites on refresh.

Cases: 61 in cases.yaml (including 6 `holdout-move` cases — excluded from runs by default; see --include-holdout). Each case's `expected` is the prod filing at extraction time; `gold` is the human (or llm-proposed) label. Re-running the seeder preserves gold/expected labels, tags, and notes byte-for-byte for cases that can be re-hydrated by source_thread_id.

Anonymization: emails, contact names, group-name contact tokens, and team names are
deterministically anonymized (shape-preserving: freemail stays freemail, org domains stay
org-shaped and equal-where-equal). Thread/priority titles and topics-without-emails are
preserved verbatim by policy. A leak check runs before every write; title-scope hits are
warnings listed by the seeder for manual audit.

## Re-generating

```bash
pnpm prod-db-connect  # if the readonly proxy isn't running
pnpm exec tsx src/seeder/from-prod.ts --user-id 019d47a8-d0a3-7a13-9b29-318faefc6ab5 --out prod-u3 --case-count 60 --holdout-recent-moves 6
```
