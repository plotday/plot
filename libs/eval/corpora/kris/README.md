# Corpus: kris

Anonymized snapshot of `kris@plot.day` extracted on 2026-05-18.

World: 31 priorities, 1188 contacts, 24 channels, 9 embeddings.

Training sets: trainings/full.yaml holds the 34 user_moved=TRUE threads pulled from prod. Add more files under trainings/ (e.g. minimal.yaml, plus-counterfactual.yaml) and the runner will matrix each one against every case.

Cases: 30 sampled auto-filed threads in cases.yaml. Each case's `expected` is the priority currently filed in prod. `gold` is unset — fill in by hand to capture cases where the current classifier disagrees with your judgment.

## Re-generating

```bash
pnpm prod-db-connect  # if proxy isn't running
pnpm tsx src/seeder/from-prod.ts --user-email kris@plot.day --out kris
```

Re-running overwrites world.yaml, trainings/full.yaml, and cases.yaml. Other training-set files under trainings/ are left untouched.