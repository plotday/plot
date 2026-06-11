<!-- Generated 2026-06-11 by: cd libs/eval && DATABASE_URL=<worktree-or-local-pg-url> pnpm exec tsx src/cli.ts --corpus kris --classifiers ts:hybrid:default,ts:hybrid-llm:default --training-sets full --format markdown (exit 1 = expected-label regressions; report still complete) -->

# Eval report — kris

Corpus: kris (prod-extract, 80 cases)

| Classifier | Training set | Gold acc. [95% CI] | Expected acc. | Regressions | LLM calls / case | Cache hit rate | Avg ms |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `ts:hybrid:default` | `full` | 20.0% [12.7–30.0] | 31.6% | 52 | 0.00 |   n/a | 6.9 |
| `ts:hybrid-llm:default` | `full` | 47.5% [36.9–58.3] | 27.6% | 55 | 0.00 | 100.0% | 19.2 |

## Stage breakdown

| Stage | Cases | Gold acc. |
| --- | --- | --- |
| `ts:hybrid:default / full → channel_default` | 4 | 25.0% |
| `ts:hybrid-llm:default / full → llm_channel_default` | 4 | 25.0% |
| `ts:hybrid:default / full → topic_shortcircuit` | 42 | 14.3% |
| `ts:hybrid-llm:default / full → llm_topic_ambiguity` | 42 | 42.9% |
| `ts:hybrid:default / full → priority_title_override` | 5 | 60.0% |
| `ts:hybrid-llm:default / full → priority_title_override` | 5 | 60.0% |
| `ts:hybrid:default / full → scoring` | 29 | 20.7% |
| `ts:hybrid-llm:default / full → llm_tiebreaker` | 26 | 61.5% |
| `ts:hybrid-llm:default / full → scoring` | 3 | 0.0% |

## Details

```
LLM tokens & estimated cost:
  [ts:hybrid-llm:default / full] live in/out=0/0  replayed in/out=89313/5266  unknown=0  est. live cost $0.0000

Rank of gold (gold-labeled cases; rates over ranked cases only):
  [ts:hybrid:default / full] top-3 55.0% (11/20 ranked)  MRR 0.513  unranked=60
  [ts:hybrid-llm:default / full] top-3 55.0% (11/20 ranked)  MRR 0.513  unranked=60

Gold accuracy by gold source (human vs llm-proposed):
  [ts:hybrid:default / full]
    human         24.1% [14.6–36.9]  n=54
    llm-proposed  11.5% [4.0–29.0]  n=26
  [ts:hybrid-llm:default / full]
    human         53.7% [40.6–66.3]  n=54
    llm-proposed  34.6% [19.4–53.8]  n=26

Training-size trajectory (gold accuracy by training threads available at case time):
  Classifier             0  1–5  6–15  16–30  31+
  ts:hybrid:default      -  -    -     -      20.0% (80)
  ts:hybrid-llm:default  -  -    -     -      47.5% (80)
```

## Gold misses

| Classifier | Training | Case | Predicted | Stage | Gold |
| --- | --- | --- | --- | --- | --- |
| `ts:hybrid:default` | `full` | `001-019e088a` | plot | channel_default | talentlift |
| `ts:hybrid-llm:default` | `full` | `001-019e088a` | plot | llm_channel_default | talentlift |
| `ts:hybrid:default` | `full` | `002-019df366` | marketing | topic_shortcircuit | finance-admin |
| `ts:hybrid-llm:default` | `full` | `002-019df366` | marketing | llm_topic_ambiguity | finance-admin |
| `ts:hybrid:default` | `full` | `004-019dbffe` | plot | channel_default | marketing |
| `ts:hybrid-llm:default` | `full` | `004-019dbffe` | plot | llm_channel_default | marketing |
| `ts:hybrid:default` | `full` | `006-019dbfe6` | plot | channel_default | kids |
| `ts:hybrid-llm:default` | `full` | `006-019dbfe6` | plot | llm_channel_default | kids |
| `ts:hybrid:default` | `full` | `008-019e2d41` | plot | scoring | marketing |
| `ts:hybrid:default` | `full` | `009-019e2d3c` | cycling | topic_shortcircuit | talentlift |
| `ts:hybrid-llm:default` | `full` | `009-019e2d3c` | elevation | llm_topic_ambiguity | talentlift |
| `ts:hybrid:default` | `full` | `010-019e2d3c` | cycling | topic_shortcircuit | income |
| `ts:hybrid-llm:default` | `full` | `010-019e2d3c` | finances | llm_topic_ambiguity | income |
| `ts:hybrid:default` | `full` | `011-019e2d3c` | cycling | topic_shortcircuit | personal |
| `ts:hybrid-llm:default` | `full` | `011-019e2d3c` | elevation | llm_topic_ambiguity | personal |
| `ts:hybrid:default` | `full` | `013-019e3392` | plot | priority_title_override | plot-user-success |
| `ts:hybrid-llm:default` | `full` | `013-019e3392` | plot | priority_title_override | plot-user-success |
| `ts:hybrid:default` | `full` | `014-019e2dd5` | plot | priority_title_override | plot-user-success |
| `ts:hybrid-llm:default` | `full` | `014-019e2dd5` | plot | priority_title_override | plot-user-success |
| `ts:hybrid:default` | `full` | `016-019de191` | product | scoring | connector-testing |
| `ts:hybrid-llm:default` | `full` | `016-019de191` | product | llm_tiebreaker | connector-testing |
| `ts:hybrid:default` | `full` | `021-019cc015` | the-plot | scoring | product |
| `ts:hybrid:default` | `full` | `024-019dff91` | the-plot | scoring | market-and-competitors |
| `ts:hybrid-llm:default` | `full` | `024-019dff91` | the-plot | llm_tiebreaker | market-and-competitors |
| `ts:hybrid:default` | `full` | `025-019dff8e` | marketing | scoring | product |
| `ts:hybrid-llm:default` | `full` | `025-019dff8e` | the-plot | llm_tiebreaker | product |
| `ts:hybrid:default` | `full` | `029-019e3868` | product | topic_shortcircuit | plot-user-success |
| `ts:hybrid:default` | `full` | `030-019e2c3d` | marketing | scoring | building-our-team |
| `ts:hybrid-llm:default` | `full` | `030-019e2c3d` | the-plot | llm_tiebreaker | building-our-team |
| `ts:hybrid:default` | `full` | `031-019e0797` | content | topic_shortcircuit | product |
| `ts:hybrid-llm:default` | `full` | `031-019e0797` | content | llm_topic_ambiguity | product |
| `ts:hybrid:default` | `full` | `032-019dac0c` | plot | topic_shortcircuit | finance-admin |
| `ts:hybrid-llm:default` | `full` | `032-019dac0c` | wififi-licensing | llm_topic_ambiguity | finance-admin |
| `ts:hybrid:default` | `full` | `033-019db0d8` | marketing | scoring | wififi-licensing |
| `ts:hybrid-llm:default` | `full` | `033-019db0d8` | the-plot | llm_tiebreaker | wififi-licensing |
| `ts:hybrid:default` | `full` | `034-019cba8e` | the-plot | scoring | finances |
| `ts:hybrid-llm:default` | `full` | `034-019cba8e` | the-plot | scoring | finances |
| `ts:hybrid:default` | `full` | `035-019db0c5` | finance-admin | scoring | product |
| `ts:hybrid:default` | `full` | `036-019cb8fe` | marketing | scoring | elevation |
| `ts:hybrid-llm:default` | `full` | `036-019cb8fe` | marketing | scoring | elevation |
| `ts:hybrid:default` | `full` | `037-019d990a` | the-plot | scoring | product |
| `ts:hybrid:default` | `full` | `038-019e2d3a` | cycling | topic_shortcircuit | talentlift |
| `ts:hybrid-llm:default` | `full` | `038-019e2d3a` | personal | llm_topic_ambiguity | talentlift |
| `ts:hybrid:default` | `full` | `039-019e2c66` | retreat | scoring | talentlift |
| `ts:hybrid-llm:default` | `full` | `039-019e2c66` | retreat | scoring | talentlift |
| `ts:hybrid:default` | `full` | `040-019d250d` | finance-admin | scoring | marketing |
| `ts:hybrid:default` | `full` | `041-019cb9a3` | product | scoring | marketing |
| `ts:hybrid:default` | `full` | `043-019cbb66` | building-our-team | topic_shortcircuit | finance-admin |
| `ts:hybrid:default` | `full` | `044-019cb9a3` | finance-admin | scoring | content |
| `ts:hybrid-llm:default` | `full` | `044-019cb9a3` | marketing | llm_tiebreaker | content |
| `ts:hybrid:default` | `full` | `045-019df0cc` | finance-admin | topic_shortcircuit | marketing |
| `ts:hybrid:default` | `full` | `046-019cbb5b` | finance-admin | scoring | marketing |
| `ts:hybrid-llm:default` | `full` | `048-019ddacc` | friends | llm_topic_ambiguity | personal |
| `ts:hybrid:default` | `full` | `049-019dac1c` | plot | topic_shortcircuit | wififi-licensing |
| `ts:hybrid:default` | `full` | `051-019e35fd` | twists | scoring | finances |
| `ts:hybrid-llm:default` | `full` | `051-019e35fd` | the-plot | llm_tiebreaker | finances |
| `ts:hybrid:default` | `full` | `054-019e2c5c` | personal | topic_shortcircuit | discipleship |
| `ts:hybrid-llm:default` | `full` | `054-019e2c5c` | personal | llm_topic_ambiguity | discipleship |
| `ts:hybrid:default` | `full` | `055-019e2c5c` | personal | topic_shortcircuit | home |
| `ts:hybrid-llm:default` | `full` | `055-019e2c5c` | personal | llm_topic_ambiguity | home |
| `ts:hybrid:default` | `full` | `056-019e2c5c` | personal | topic_shortcircuit | marketing |
| `ts:hybrid-llm:default` | `full` | `056-019e2c5c` | personal | llm_topic_ambiguity | marketing |
| `ts:hybrid:default` | `full` | `057-019e2d37` | cycling | topic_shortcircuit | marketing |
| `ts:hybrid-llm:default` | `full` | `057-019e2d37` | elevation | llm_topic_ambiguity | marketing |
| `ts:hybrid:default` | `full` | `058-019e2d2c` | cycling | topic_shortcircuit | kids |
| `ts:hybrid-llm:default` | `full` | `058-019e2d2c` | personal | llm_topic_ambiguity | kids |
| `ts:hybrid:default` | `full` | `059-019ddacd` | product | topic_shortcircuit | testing |
| `ts:hybrid-llm:default` | `full` | `059-019ddacd` | product | llm_topic_ambiguity | testing |
| `ts:hybrid:default` | `full` | `061-019db068` | marketing | scoring | plot |
| `ts:hybrid-llm:default` | `full` | `061-019db068` | product | llm_tiebreaker | plot |
| `ts:hybrid:default` | `full` | `062-019dac10` | plot | topic_shortcircuit | marketing |
| `ts:hybrid-llm:default` | `full` | `062-019dac10` | plot | llm_topic_ambiguity | marketing |
| `ts:hybrid:default` | `full` | `063-019dab37` | product | scoring | plot-user-success |
| `ts:hybrid:default` | `full` | `065-019d654e` | product | scoring | marketing |
| `ts:hybrid:default` | `full` | `066-019d46d5` | product | topic_shortcircuit | hr-committee |
| `ts:hybrid-llm:default` | `full` | `066-019d46d5` | finance-admin | llm_topic_ambiguity | hr-committee |
| `ts:hybrid:default` | `full` | `067-019cd33e` | finance-admin | scoring | content |
| `ts:hybrid-llm:default` | `full` | `067-019cd33e` | market-and-competitors | llm_tiebreaker | content |
| `ts:hybrid:default` | `full` | `068-019cc122` | product | scoring | content |
| `ts:hybrid:default` | `full` | `069-019e0fa3` | finance-admin | topic_shortcircuit | product |
| `ts:hybrid:default` | `full` | `070-019dd544` | marketing | scoring | content |
| `ts:hybrid-llm:default` | `full` | `070-019dd544` | product | llm_tiebreaker | content |
| `ts:hybrid:default` | `full` | `071-019e2c95` | cycling | topic_shortcircuit | elevation |
| `ts:hybrid:default` | `full` | `072-019e2c59` | retreat | topic_shortcircuit | marketing |
| `ts:hybrid-llm:default` | `full` | `072-019e2c59` | retreat | llm_topic_ambiguity | marketing |
| `ts:hybrid:default` | `full` | `074-019e2cbf` | cycling | topic_shortcircuit | finances |
| `ts:hybrid:default` | `full` | `075-019e2cd5` | cycling | topic_shortcircuit | finances |
| `ts:hybrid:default` | `full` | `076-019e2c75` | cycling | topic_shortcircuit | elevation |
| `ts:hybrid:default` | `full` | `077-019e2c6b` | cycling | topic_shortcircuit | friends |
| `ts:hybrid-llm:default` | `full` | `077-019e2c6b` | personal | llm_topic_ambiguity | friends |
| `ts:hybrid:default` | `full` | `078-019e2cc6` | cycling | topic_shortcircuit | finance-admin |
| `ts:hybrid-llm:default` | `full` | `078-019e2cc6` | finances | llm_topic_ambiguity | finance-admin |
| `ts:hybrid:default` | `full` | `079-019e2c93` | cycling | topic_shortcircuit | elevation |
| `ts:hybrid:default` | `full` | `081-019e2c60` | talentlift | topic_shortcircuit | hr-committee |
| `ts:hybrid-llm:default` | `full` | `081-019e2c60` | governance-committee | llm_topic_ambiguity | hr-committee |
| `ts:hybrid:default` | `full` | `082-019e2c60` | talentlift | topic_shortcircuit | hr-committee |
| `ts:hybrid:default` | `full` | `083-019e2c83` | cycling | topic_shortcircuit | plot |
| `ts:hybrid-llm:default` | `full` | `083-019e2c83` | personal | llm_topic_ambiguity | plot |
| `ts:hybrid:default` | `full` | `084-019e2c62` | talentlift | topic_shortcircuit | income |
| `ts:hybrid-llm:default` | `full` | `084-019e2c62` | talentlift | llm_topic_ambiguity | income |
| `ts:hybrid:default` | `full` | `085-019e2c59` | talentlift | topic_shortcircuit | hr-committee |
| `ts:hybrid:default` | `full` | `086-019e2c5b` | cycling | topic_shortcircuit | personal |
| `ts:hybrid-llm:default` | `full` | `086-019e2c5b` | finances | llm_topic_ambiguity | personal |
| `ts:hybrid:default` | `full` | `087-019e2c5a` | cycling | topic_shortcircuit | personal |
| `ts:hybrid-llm:default` | `full` | `087-019e2c5a` | cycling | llm_topic_ambiguity | personal |
| `ts:hybrid:default` | `full` | `088-019e2c5d` | cycling | topic_shortcircuit | personal |
