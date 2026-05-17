# Corpus: kris

Anonymized snapshot of `kris@plot.day` extracted on 2026-05-17.

World: 31 priorities, 1188 contacts, 24 channels, 34 training threads, 9 embeddings.

Cases: 30 sampled auto-filed threads. Each case's `expected` is the priority currently filed in prod, so `sql:current` should agree by construction. `gold` is unset — fill in by hand to capture cases where the current classifier disagrees with your judgment.

## Re-generating

```bash
pnpm prod-db-connect  # if proxy isn't running
pnpm tsx src/seeder/from-prod.ts --user-email kris@plot.day --out kris
```

Anonymization is deterministic per `anonymize.NAMESPACE`, so re-runs produce 
stable UUIDs and embeddings. Re-running will overwrite the corpus files.