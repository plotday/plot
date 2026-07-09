# Twist Generation Prompt Curation — Design

**Date:** 2026-07-09
**Status:** Approved (brainstorming complete)
**Branches:** core `twist-gen-prompt-curation` (off main, post core#647); public submodule `twist-prompt-curation` (off plotday/plot main)

## Purpose

The third improvement PR from the generation-reliability roadmap: curate the
prompt content. Today the system prompt embeds the FULL source of every
twister module (~68K tokens) — including the entire `Connector` base class,
which twists must never extend (the corpus carries `notMatch: extends
Connector` guards precisely because it confuses generation) — and contains
zero complete example twists. The consistently-failing corpus categories
(ai-intents, auth-integration — 6 of the 6 Pro failures in the pr-b run)
fail on tool-WIRING subtleties that type definitions alone don't teach;
whole-program exemplars anchor those patterns.

Measured against the pr-b references
(`evals/results/20260709-021506-pr-b.json` Pro 75%,
`evals/results/20260709-022136-pr-b-flash.json` flash 71%).

## Decisions (from brainstorming)

1. **Trim scope: `connector.ts` + `tools/imap.ts` + `tools/smtp.ts`**
   (~12.4K tokens) out of the twist prompt. Accepted trade (user decision):
   mail-protocol tools are valid twist tools, so a mail-workflow spec loses
   its reference docs — unmeasured by the corpus; revisit if a mail-twist
   use case appears.
2. **Three exemplars targeting the weak patterns**, in domains distinct
   from the corpus specs (no teaching-to-the-test):
   - `ai-responder.ts` — reacts to new notes, uses the AI tool, replies in
     thread (pattern behind the ai-intents failures). Domain: translating
     notes into plain English summaries for a language-learning journal.
   - `authenticated-sync.ts` — OAuth-style integration auth, periodic
     import, source/key upserts (pattern behind auth-integration
     failures). Domain: importing starred items from a bookmarking
     service.
   - `scheduled-digest.ts` — recurring schedule + external fetch + thread
     creation. Domain: weather-forecast morning digest.
3. **Exemplars are real compilable sources** in the twister package,
   typechecked by the package build (rot-proof), embedded into the prompt
   string at prebuild — the same mechanism as `AGENTS.template.md` →
   `twist-guide-template.ts`.
4. **Export surface:** both new symbols ship from the existing
   `@plotday/twister/creator-docs` entry (no new package-exports entry):
   `getTwistDocumentation(): string` and `TWIST_EXEMPLARS: string`.
   `getBuilderDocumentation()` is unchanged for API stability.

## Non-goals

- No prompt-STRUCTURE changes beyond content (instructions/messages layout,
  caching markers, retry conversation: all untouched — PR B owns those).
- No corpus changes (the measurement instrument stays fixed).
- No removal of `getBuilderDocumentation()`.
- No model/routing/builder changes.

## Changes

### Public submodule (`public/twister`) — branch `twist-prompt-curation`

- `src/exemplars/ai-responder.ts`, `src/exemplars/authenticated-sync.ts`,
  `src/exemplars/scheduled-digest.ts`: each a complete, minimal,
  idiomatic twist (default-exported class extending `Twist<Self>`,
  `build()` tool declarations, callbacks via `this.callback`, store for
  state, source/key upserts where applicable), 40–80 lines, headed by a
  `/* SPEC: ... */` block comment written the way a user would describe the
  twist. They are part of the package's tsc build (`include` covers
  `src/**`) so every build typechecks them; they are EXCLUDED from the
  llm-docs type-definition generation in `prebuild.ts` (skip
  `./exemplars`-adjacent paths — they are not package exports at all,
  just sources).
- `prebuild.ts`: after the twist-guide generation, read
  `src/exemplars/*.ts`, split each into spec (the leading block comment)
  and implementation (the rest), and generate
  `src/llm-docs/twist-exemplars.ts` exporting a single formatted string:
  `## Example: <FileTitle>` / `### Specification` / `<spec text>` /
  `### Implementation` / ```` ```typescript … ``` ````.
- `src/creator-docs.ts`:
  - `export function getTwistDocumentation(): string` — same header and
    per-module formatting as `getBuilderDocumentation()`, but skipping the
    import paths `@plotday/twister/connector`,
    `@plotday/twister/tools/imap`, `@plotday/twister/tools/smtp`.
  - `export { TWIST_EXEMPLARS } from "./llm-docs/twist-exemplars.js";`
    (matching the file's existing import/export style).
- Changeset (`public/.changeset/twist-prompt-docs.md`, minor):
  `Added: getTwistDocumentation() (twist-scoped LLM documentation) and TWIST_EXEMPLARS (complete example twists) for generation prompts.`
- Public PR text: external audience, no core-repo internals or measurement
  program references beyond "improves generated-twist quality".

### Core (`workers/api`)

- `generator.ts`: import `getTwistDocumentation` and `TWIST_EXEMPLARS`
  from `@plotday/twister/creator-docs`; the system prompt becomes:

  ```ts
  const systemPrompt = `You are an expert at generating Plot twists.

  ${sdkDocs}

  ${TWIST_GUIDE}

  # Complete examples

  ${TWIST_EXEMPLARS}`;
  ```

  with `const sdkDocs = getTwistDocumentation();`. Static per version →
  provider caching preserved.
- `generator.test.ts`: the creator-docs mock gains
  `getTwistDocumentation: () => "<TWIST_DOCS>"` and
  `TWIST_EXEMPLARS: "<EXEMPLARS>"`; prompt assertions updated to require
  `<TWIST_DOCS>` and `<EXEMPLARS>` and (new) to REJECT the old
  `getBuilderDocumentation` stub if present (assert the builder function is
  no longer called).
- Submodule gitlink bump to the public branch tip (re-pointed to the
  merged commit after the public PR lands, per the established dance).

## Error handling

Build-time only: prebuild fails loudly if an exemplar lacks the leading
spec comment or the exemplars dir is empty (broken generation would
otherwise silently ship an empty examples section).

## Verification

1. Twister: `pnpm build` in `public/twister` (typechecks exemplars,
   generates the embed); `pnpm validate-changesets` in `public/`; a small
   unit-style assertion script or test that `getTwistDocumentation()`
   excludes the three modules and `TWIST_EXEMPLARS` contains all three
   example headers (twister has no test runner — a `prebuild`-time
   assertion or a core-side unit test in `generator.test.ts` scope
   covers it; decided at plan time).
2. Core: generator tests updated; lint clean.
3. **Measurement (~$7):** Pro `--label pr-c --runs 2 --compare
   evals/results/20260709-021506-pr-b.json` and flash `--model
   gemini-3-flash-preview --label pr-c-flash --runs 2` vs the pr-b flash
   reference. Gates: no regression (Pro ≥ 75% − noise, flash ≥ 71% −
   noise, >8pp drop = stop); target: assertion_failed reduction,
   especially ai-intents / auth-integration; input tokens per call net
   lower (−12.4K trim, +~4K exemplars).

## Success criteria

- The twist prompt contains no Connector/imap/smtp module docs and three
  complete exemplars; total prompt tokens net lower than before.
- Exemplars are compiled on every twister build (rot-proof).
- Public PR + changeset land cleanly; core references the merged gitlink.
- Measurement gates pass; the weak-category failures move.
