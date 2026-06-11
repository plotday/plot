# Faster focus matching + reassuring wait — design

**Date:** 2026-06-11
**Area:** Focus creation, step 2 ("Find matching threads")

## Problem

When creating a focus, "Find matching threads" now makes LLM calls, so it can
take several seconds. Two issues:

1. **Latency.** Two independent LLM calls run sequentially before the DB search.
2. **Waiting UX.** The only feedback is a spinner on the button. The user sits on
   step 1 with no sense that work is progressing.

## Goals

- Shave the avoidable latency without changing match quality.
- Replace the button spinner with an immediate navigation to the step-2 modal
  that shows friendly, changing status content while results are computed, then
  populates in place.

## Non-goals

- No streaming/SSE protocol, no incremental partial results.
- No database or schema changes.
- No new modal type — reuse the existing form framework.
- The status messages are timer-driven reassurance, not tied to real backend
  stages.

## Current flow (for reference)

- **Backend:** `POST /sync/priorities/find-matching-threads`
  (`workers/api/src/app/sync/priority-match.ts`) runs, in order:
  1. `deriveFacetFilters` (Gemini, ~1–3s)
  2. `embedText` (Workers AI embedding, ~0.5–2s)
  3. vector + lexical DB search
  4. `rerankWithLlm` (Gemini, ~3–8s) — the bulk of the time, and the value.
  Steps 1 and 2 are independent but run sequentially.
- **Flutter:** `_FindMatchingThreads.run` (`apps/plot/lib/command/priority.dart`)
  awaits the POST, hydrates each match from the local store, then pushes
  `_ShowFocusMatches` (a `ShowForm`). `ShowForm.run` awaits the form future
  before showing anything, so the wait is spent with a spinner on the step-1
  button (`form.dart`).

## Design

### 1. Backend: parallelize the two independent LLM calls

In `priority-match.ts`, run facet derivation and embedding concurrently instead
of sequentially:

```ts
const [facetResult, embedResult] = await Promise.allSettled([
  deriveFacetFilters(c.env, title, description),
  embedText(c.env, title ? `${title}\n\n${description}` : description),
]);
```

- **Embedding is required.** If `embedResult` is rejected, log a warning (as
  today) and return `{ matches: [], error: "llm_unavailable" }`.
- **Facet derivation fails open.** If `facetResult` is rejected, treat the
  derived filters as `null` (no extra filtering). `deriveFacetFilters` already
  returns `null` on its own internal failure; this just extends the same
  behavior to a thrown error. `facetFilterJson` is computed from the fulfilled
  value or `null`.
- No change to the search, re-rank, fallback, or response shape.
- Expected saving: ~1–3s of the total wait.

### 2. Flutter: show the modal immediately, populate in place

Reuse the existing `FormData.onRefresh` / `FormScope.refresh()` mechanism (it
already rebuilds a modal's groups in place; today it fires when a child modal
pops). The progress widget will call `refresh()` itself when the fetch lands.

**`_FindMatchingThreads.run`:**
- Starts the fetch **without awaiting it** — builds a `Future<_MatchResult>`
  that performs the POST and local-store hydration (the logic that lives in
  `run` today, moved into a function/method).
- Immediately runs `_ShowFocusMatches`, passing the in-flight future. Navigation
  no longer waits on the network, so the step-1 button no longer shows a gating
  spinner for the full duration.

**`_MatchResult`:** a small holder for the outcome the modal needs:
- `matches: List<_FocusMatch>` (empty on no-match or error)
- `failed: bool` (the POST/hydration threw — distinct from "no matches")

**`_ShowFocusMatches` (form builder):**
- A shared mutable holder (e.g. a tiny controller object captured by the form
  builder) tracks whether the result has arrived: `_MatchResult? result`.
- **While `result == null` (loading):** the form has a single group containing a
  `FormInfo` whose `content` is a `_MatchingProgress` widget, plus **no** Create
  button (nothing to create yet; Back/Esc returns to step 1).
- **Once `result != null`:** `onRefresh` rebuilds into the existing review UI:
  - `failed == true` → a `FormInfo` explaining matching didn't work, plus the
    Create button (user can still create the focus). Reuses the existing
    "fall through with no matches" intent.
  - `matches.isEmpty` → the existing "No matching threads found yet…" `FormInfo`
    + Create button.
  - otherwise → the existing matches hint + `FormToggle` per match (strong
    matches pre-checked) + Create button. This is the current
    `_buildFocusMatchesForm` body, unchanged.

**`_MatchingProgress` (new `StatefulWidget`):**
- Renders a spinner + one status line.
- A periodic timer (~1.8s) advances through the friendly messages, looping if
  the fetch outlasts the list.
- In `initState`, `await`s the passed future, writes the outcome into the shared
  holder, then — after a minimum display window (~600ms from first paint, so a
  fast response doesn't flash) — calls `FormScope.of(context)?.refresh?.call()`
  to swap the modal into the review UI.
- Cancels its timer in `dispose`. Guards all post-await work on `mounted` /
  context-mounted.
- Errors from the future are captured via `Tracker.captureException` (as the
  current `catch` does) and surface as `failed == true`.

### 3. Status messages

Friendly, no reference to AI / scoring / models. Cycled in order, looping:

1. "Looking through your threads…"
2. "Finding what fits…"
3. "Gathering the best matches…"
4. "Almost ready…"

## Edge cases

- **Fast response (< min window):** the ~600ms minimum display window prevents a
  flash of the progress UI.
- **Failure:** network/API/hydration error → `failed == true` → review step
  shows a brief "couldn't check for matches" info and still offers Create.
  Matches today's "fall through with no matches" behavior, just surfaced in the
  modal instead of silently.
- **No matches:** existing empty-state info + Create button.
- **Back/Esc during loading:** returns to step 1 with the description intact
  (unchanged nesting behavior). The in-flight future is abandoned; its
  completion is guarded by `mounted`.
- **Onboarding (`skipMatching`):** unaffected — it never reaches this flow.

## Testing

- **Backend:** verify `find-matching-threads` still returns the same shape and
  that a thrown `deriveFacetFilters` no longer aborts the request (matches still
  returned). Confirm a thrown embedding still yields `llm_unavailable`.
  Manual/`run-app` check for the latency improvement.
- **Flutter:** `flutter analyze` clean. `run-app` walkthrough: create a focus,
  confirm the modal appears immediately with cycling messages, then populates
  with matches; confirm no-match and (simulated) error states render with a
  working Create button; confirm Back during loading returns to step 1.

## Files touched

- `workers/api/src/app/sync/priority-match.ts` — parallelize §1.
- `apps/plot/lib/command/priority.dart` — §2 + §3: split the fetch out of
  `_FindMatchingThreads.run`, add `_MatchResult`, the shared holder, the
  loading/review branching in the `_ShowFocusMatches` form builder + `onRefresh`,
  and the `_MatchingProgress` widget.
- Possibly a small spinner/status helper alongside `_MatchingProgress` in the
  same file (kept local unless it's reusable).
