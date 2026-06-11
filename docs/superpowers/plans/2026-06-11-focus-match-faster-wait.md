# Faster focus matching + reassuring wait — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut the avoidable latency in "Find matching threads" and replace the button spinner with an immediate step-2 modal that shows friendly cycling status content, then populates in place.

**Architecture:** Backend runs the two independent LLM calls (facet derivation + embedding) concurrently. Flutter starts the fetch without awaiting, navigates straight to the step-2 modal showing a self-cycling progress widget, and rebuilds into the existing review UI via the form framework's `onRefresh`/`FormScope.refresh()` seam when the result lands.

**Tech Stack:** TypeScript (Cloudflare Workers, Hono), Dart/Flutter (forui, custom form/modal framework).

**Design spec:** `docs/superpowers/specs/2026-06-11-focus-match-faster-wait-design.md`

---

## File structure

- `workers/api/src/app/sync/priority-match.ts` — parallelize the facet-derivation and embedding calls (Task 1).
- `apps/plot/lib/command/priority.dart` — extract the fetch, add the result holder, the progress widget, and the immediate-navigation + `onRefresh` branching (Tasks 2–3).
- `docs/updates.md` — user-facing changelog bullet (Task 4).

## Background the implementer needs

- **No isolated unit test exists for the `find-matching-threads` route** — it depends on Workers AI + the DB inside a Hono handler. The backend change is a behavior-preserving refactor; it is verified by the TypeScript compiler (`pnpm lint` runs `tsc`) plus the run-app walkthrough in Task 4. Per the project's tooling notes, `main` already has 2 pre-existing `tsc` errors in `workers/api`; the gate is **no NEW `error TS`**, not zero.
- **Flutter commands in this codebase are not unit-tested.** The Flutter gate is `flutter analyze` (CI runs it with `--no-fatal-infos`) plus the run-app walkthrough. Every Flutter task must leave the code compiling cleanly so `flutter analyze` stays green.
- **Form refresh seam:** `FormData.onRefresh` returns rebuilt groups; `FormScope.of(context)?.refresh?.call()` triggers `_refreshForm` (`apps/plot/lib/widget/form_modal.dart:129`), which calls `onRefresh()`, tears down old items, restores values by key, rebuilds, and `setState`s. A `FormInfo` hosts a custom widget through its `builder:` parameter (NOT `content:` — that's `FormToggle`). `Spinner` is exported via `package:plot/widget/widget.dart` (already imported). `dart:async` (for `Timer`) is already imported.

---

### Task 1: Backend — run facet derivation and embedding concurrently

**Files:**
- Modify: `workers/api/src/app/sync/priority-match.ts:154-166`

- [ ] **Step 1: Replace the sequential block with a concurrent one**

Find this block (currently lines 154–166):

```ts
  const derived = await deriveFacetFilters(c.env, title, description);
  const facetFilterJson = derived ? JSON.stringify(derived) : null;

  // Embed the focus's title + description together (title adds a strong signal
  // for short descriptions). Fall back gracefully if embedding is unavailable.
  let queryEmbedding: number[];
  try {
    queryEmbedding = await embedText(c.env, title ? `${title}\n\n${description}` : description);
  } catch (error) {
    logger.warn("focus-match embedding failed", { error: (error as Error).message });
    return c.json({ matches: [], error: "llm_unavailable" as MatchErrorCode });
  }
  const queryJson = JSON.stringify(queryEmbedding);
```

Replace it with:

```ts
  // Facet derivation (Gemini) and embedding (Workers AI) are independent, so run
  // them concurrently instead of serially — shaves ~1–3s off the wait. Embedding
  // is required; facet derivation fails open (null → no extra filtering).
  const [facetResult, embedResult] = await Promise.allSettled([
    deriveFacetFilters(c.env, title, description),
    embedText(c.env, title ? `${title}\n\n${description}` : description),
  ]);

  if (embedResult.status === "rejected") {
    logger.warn("focus-match embedding failed", {
      error: (embedResult.reason as Error)?.message,
    });
    return c.json({ matches: [], error: "llm_unavailable" as MatchErrorCode });
  }
  const queryEmbedding = embedResult.value;
  const queryJson = JSON.stringify(queryEmbedding);

  // deriveFacetFilters already returns null on its own internal failure; extend
  // the same fail-open behavior to a thrown error so matching still proceeds.
  if (facetResult.status === "rejected") {
    logger.warn("focus-match facet derivation failed", {
      error: (facetResult.reason as Error)?.message,
    });
  }
  const derived = facetResult.status === "fulfilled" ? facetResult.value : null;
  const facetFilterJson = derived ? JSON.stringify(derived) : null;
```

This keeps `facetFilterJson` and `queryJson` defined before the `visible` SQL predicate (line ~175) that consumes them. No change to the search, re-rank, fallback, or response shape.

- [ ] **Step 2: Lint (typecheck) the package**

Run: `cd workers/api && pnpm lint`
Expected: no NEW `error TS` lines referencing `priority-match.ts`. (Up to 2 pre-existing `tsc` errors elsewhere are acceptable per the tooling notes; confirm none are new and none are in `priority-match.ts`.)

- [ ] **Step 3: Commit**

```bash
cd /Users/kris.braun/code/plot
git add workers/api/src/app/sync/priority-match.ts
git commit -m "perf(focus-match): run facet derivation and embedding concurrently

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>" -- workers/api/src/app/sync/priority-match.ts
```

---

### Task 2: Flutter — extract the fetch into `_fetchMatches` + `_MatchResult` (behavior-preserving)

This refactor moves the network/hydration logic out of `_FindMatchingThreads.run` into a standalone function and a small result holder, keeping the existing await-then-navigate behavior. Task 3 then rewires navigation.

**Files:**
- Modify: `apps/plot/lib/command/priority.dart` (the `_FindMatchingThreads` class, lines ~786-859)

- [ ] **Step 1: Add the `_MatchResult` holder**

Immediately above the `_FindMatchingThreads` class (around line 786), add:

```dart
/// Outcome of the background match fetch, surfaced to the review step.
class _MatchResult {
  const _MatchResult({required this.matches, required this.failed});

  /// The fetch (or local-store hydration) threw — distinct from "no matches".
  const _MatchResult.failure() : matches = const [], failed = true;

  final List<_FocusMatch> matches;
  final bool failed;
}

/// Fetches the threads that match [description]/[title] and hydrates each from
/// the local store. Never throws: failures are captured and returned as
/// [_MatchResult.failure] so the review step can still offer "Create focus".
Future<_MatchResult> _fetchMatches({
  required String description,
  required String title,
}) async {
  try {
    final resp = await api.post<Map<String, dynamic>>(
      '/sync/priorities/find-matching-threads',
      body: {'description': description, 'title': title},
    );
    final raw = (resp['matches'] as List?) ?? const [];
    final parsed = [
      for (final m in raw)
        if (m is Map && m['thread_id'] is String)
          (
            threadId: m['thread_id'] as String,
            title: (m['title'] as String?)?.trim().isNotEmpty == true
                ? m['title'] as String
                : 'Untitled thread',
            // Default to a strong score when absent so older responses keep
            // their pre-checked behaviour.
            score: (m['score'] as num?)?.toDouble() ?? 1.0,
          ),
    ];
    // Hydrate each match from the local store so the review rows render the
    // full thread (logo, header, title, preview). Best-effort: a thread that
    // can't be loaded falls back to its title in the row.
    final threads = await Future.wait([
      for (final p in parsed)
        Thread.getOne(Uuid.fromString(p.threadId)).then<Thread?>(
          (t) => t,
          onError: (_) => null,
        ),
    ]);
    return _MatchResult(
      matches: [
        for (var i = 0; i < parsed.length; i++)
          _FocusMatch(
            threadId: parsed[i].threadId,
            title: parsed[i].title,
            score: parsed[i].score,
            thread: threads[i],
          ),
      ],
      failed: false,
    );
  } catch (e, stackTrace) {
    Tracker.captureException(e, stackTrace);
    // Fall through with no matches — the user can still create the focus.
    return const _MatchResult.failure();
  }
}
```

- [ ] **Step 2: Rewrite `_FindMatchingThreads.run` to call `_fetchMatches`**

Replace the body of `_FindMatchingThreads.run` (the whole method, lines ~802-858) with:

```dart
  @override
  Future<CommandReturn> run(BuildContext context) async {
    final description = (values['description'] as String? ?? '').trim();
    final title = (values['title'] as String? ?? '').trim();

    final result = await _fetchMatches(description: description, title: title);

    if (!context.mounted) return const CommandSkipped();
    return _ShowFocusMatches(
      values: values,
      root: root,
      matches: result.matches,
      suggestionKey: suggestionKey,
    ).run(context);
  }
```

(`_ShowFocusMatches` still takes `matches:` at this point — Task 3 changes its signature.)

- [ ] **Step 3: Analyze**

Run: `cd apps/plot && flutter analyze lib/command/priority.dart`
Expected: No errors. (No new warnings from the extracted code.)

- [ ] **Step 4: Commit**

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/lib/command/priority.dart
git commit -m "refactor(focus-match): extract _fetchMatches and _MatchResult

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>" -- apps/plot/lib/command/priority.dart
```

---

### Task 3: Flutter — immediate navigation, progress widget, populate-in-place

Now wire the show-immediately flow: start the fetch without awaiting, push the step-2 modal in a loading state, cycle friendly messages, and rebuild into the review UI when the result lands.

**Files:**
- Modify: `apps/plot/lib/command/priority.dart` (`_FindMatchingThreads.run`, `_ShowFocusMatches`, `_buildFocusMatchesForm`; add `_MatchLoadState` and `_MatchingProgress`)

- [ ] **Step 1: Add the shared load-state holder**

Directly below the `_fetchMatches` function added in Task 2, add:

```dart
/// Shared, mutable holder bridging the step-2 form builder and the in-modal
/// progress widget. The progress widget writes [result] when the fetch lands,
/// then triggers a form refresh so the builder rebuilds into the review UI.
class _MatchLoadState {
  _MatchLoadState(this.future);

  final Future<_MatchResult> future;

  /// Null while the fetch is in flight; set once it completes.
  _MatchResult? result;
}
```

- [ ] **Step 2: Add the `_MatchingProgress` widget**

Add this widget below `_MatchLoadState`:

```dart
/// Friendly, no-jargon status messages cycled while matching runs. Timer-driven
/// reassurance (not tied to real backend stages), looped if the fetch outlasts
/// the list.
const List<String> _matchingStatusMessages = [
  'Looking through your threads…',
  'Finding what fits…',
  'Gathering the best matches…',
  'Almost ready…',
];

/// Minimum time the progress UI stays up so a fast response doesn't flash.
const Duration _matchingMinDisplay = Duration(milliseconds: 600);

/// How long each status message shows before advancing.
const Duration _matchingMessageInterval = Duration(milliseconds: 1800);

/// In-modal progress shown while [load.future] is in flight. Cycles a spinner +
/// friendly status line, and on completion writes [load.result] and refreshes
/// the surrounding form into the review UI.
class _MatchingProgress extends StatefulWidget {
  const _MatchingProgress({required this.load});

  final _MatchLoadState load;

  @override
  State<_MatchingProgress> createState() => _MatchingProgressState();
}

class _MatchingProgressState extends State<_MatchingProgress> {
  int _messageIndex = 0;
  Timer? _cycleTimer;

  @override
  void initState() {
    super.initState();
    _cycleTimer = Timer.periodic(_matchingMessageInterval, (_) {
      if (!mounted) return;
      setState(() {
        _messageIndex = (_messageIndex + 1) % _matchingStatusMessages.length;
      });
    });
    _awaitResult();
  }

  Future<void> _awaitResult() async {
    final start = DateTime.now();
    final result = await widget.load.future;
    widget.load.result = result;

    // Hold the progress UI for at least the minimum window.
    final elapsed = DateTime.now().difference(start);
    final remaining = _matchingMinDisplay - elapsed;
    if (remaining > Duration.zero) {
      await Future<void>.delayed(remaining);
    }

    if (!mounted) return;
    // Rebuild the surrounding form into the review UI.
    await FormScope.of(context)?.refresh?.call();
  }

  @override
  void dispose() {
    _cycleTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: context.theme.spacing.xl,
        vertical: context.theme.spacing.lg,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 8,
        children: [
          const Spinner(),
          Flexible(
            child: Text(
              _matchingStatusMessages[_messageIndex],
              style: context.theme.typography.md.copyWith(
                color: context.theme.colors.mutedForeground,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 3: Rewrite `_FindMatchingThreads.run` to navigate immediately**

Replace the method body added in Task 2 with:

```dart
  @override
  Future<CommandReturn> run(BuildContext context) async {
    final description = (values['description'] as String? ?? '').trim();
    final title = (values['title'] as String? ?? '').trim();

    // Start the fetch but DON'T await it — navigate to the review modal right
    // away so the user sees progress instead of a button spinner. The modal's
    // progress widget observes this future and populates the form when it lands.
    final load = _MatchLoadState(
      _fetchMatches(description: description, title: title),
    );

    return _ShowFocusMatches(
      values: values,
      root: root,
      load: load,
      suggestionKey: suggestionKey,
    ).run(context);
  }
```

- [ ] **Step 4: Change `_ShowFocusMatches` to take the load holder**

Replace the `_ShowFocusMatches` class (lines ~892-909) with:

```dart
/// Step 2 of [NewFocus]: review the threads that match the description. Pushed
/// as a nested modal by [_FindMatchingThreads], so the form header shows a Back
/// button and Esc returns to step 1 to edit the description and search again.
/// Shown immediately in a loading state; [_MatchingProgress] refreshes it into
/// the review UI once [load] completes.
class _ShowFocusMatches extends ShowForm {
  _ShowFocusMatches({
    required Map<String, dynamic> values,
    required Priority root,
    required _MatchLoadState load,
    String? suggestionKey,
  }) : super(
         title: 'Add a focus',
         icon: PlotIcon.add,
         form: (ctx) => _buildFocusMatchesForm(
           ctx,
           values: values,
           root: root,
           load: load,
           suggestionKey: suggestionKey,
         ),
       );
}
```

- [ ] **Step 5: Rewrite `_buildFocusMatchesForm` to branch on load state**

Replace `_buildFocusMatchesForm` (lines ~911-964) with:

```dart
Future<FormData> _buildFocusMatchesForm(
  BuildContext context, {
  required Map<String, dynamic> values,
  required Priority root,
  required _MatchLoadState load,
  String? suggestionKey,
}) async {
  Future<List<StaticFormGroup>> buildGroups() async {
    final result = load.result;

    // Still loading: cycling progress, no Create button yet (Back/Esc returns
    // to step 1).
    if (result == null) {
      return [
        StaticFormGroup(
          items: [
            FormInfo(
              key: 'matching_progress',
              builder: (ctx) => _MatchingProgress(load: load),
            ),
          ],
        ),
      ];
    }

    // Loaded: review UI (failure / empty / matches) + Create button.
    final matches = result.matches;
    return [
      StaticFormGroup(
        items: [
          if (result.failed)
            FormInfo(
              key: 'match_failed',
              text:
                  'We couldn’t check for matching threads just now. Create the '
                  'focus and file threads into it as they come in.',
            )
          else if (matches.isEmpty)
            FormInfo(
              key: 'no_matches',
              text:
                  'No matching threads found yet. Create the focus and file '
                  'threads into it as they come in.',
            )
          else ...[
            FormInfo(
              key: 'matches_hint',
              text: matches.any((m) => m.isStrong)
                  ? 'Plot checked the threads it’s confident belong here. Check '
                        'any others that fit, and uncheck any that don’t.'
                  : 'These threads might belong in this focus. Check the ones '
                        'that fit.',
            ),
            for (final m in matches)
              FormToggle(
                key: 'match_${m.threadId}',
                label: m.title,
                content: m.thread != null
                    ? ThreadSummary(thread: m.thread!)
                    : null,
                initialValue: m.isStrong,
              ),
          ],
          FormButton(
            key: 'create',
            isPrimary: true,
            buildCommand: (selections) => _CreateFocusWithThreads(
              values: values,
              root: root,
              matches: matches,
              selections: selections,
              suggestionKey: suggestionKey,
            ),
          ),
        ],
      ),
    ];
  }

  return FormData(
    title: 'Add a focus',
    groups: await buildGroups(),
    onRefresh: buildGroups,
  );
}
```

- [ ] **Step 6: Analyze**

Run: `cd apps/plot && flutter analyze lib/command/priority.dart`
Expected: No errors.

- [ ] **Step 7: Commit**

```bash
cd /Users/kris.braun/code/plot
git add apps/plot/lib/command/priority.dart
git commit -m "feat(focus-match): show step-2 modal immediately with cycling progress

Navigate to the review modal as soon as matching starts and reassure with
friendly cycling status text, then populate in place via form onRefresh.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>" -- apps/plot/lib/command/priority.dart
```

---

### Task 4: Verify end-to-end + changelog

**Files:**
- Modify: `docs/updates.md`

- [ ] **Step 1: Run the app and walk the flow**

Invoke the `run-app` skill. Then:
1. Open "Add a focus" → "Create a custom focus" (or a suggestion).
2. Fill name + a description that should match some existing threads. Click "Find matching threads".
3. **Confirm:** the modal appears immediately (no lingering button spinner), shows the spinner + a status line, and the status line advances through the friendly messages.
4. **Confirm:** when results arrive, the modal rebuilds in place into the match toggles with a working "Create focus" button; strong matches are pre-checked.
5. **Confirm:** pressing Esc/Back while still loading returns to step 1 with the description intact.
6. **Confirm empty state:** use a nonsense description with no matches → modal shows the "No matching threads found yet" info + Create button.
7. Optionally confirm the failure path by stopping the local API worker before clicking, → modal shows "We couldn’t check for matching threads just now" + Create button.

Note any glitch (e.g. a form with no focusable item mishandling keyboard focus during loading) and fix before continuing.

- [ ] **Step 2: Add a user-facing changelog bullet**

In `docs/updates.md`, under the top `## Next release` heading, add to an existing `### Focuses` section if present, else create one above `### Fixes`:

```markdown
### Focuses

- Finding matching threads when you create a focus is faster, and now opens the
  results right away with a friendly progress indicator instead of waiting on a
  button.
```

(Match the file's existing structure; don't add `---` separators or a version heading.)

- [ ] **Step 3: Commit**

```bash
cd /Users/kris.braun/code/plot
git add docs/updates.md
git commit -m "docs(updates): note faster focus matching + progress UI

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>" -- docs/updates.md
```

- [ ] **Step 4: Finalize**

Invoke the `/finalize` skill to run the change-finalization checklist (lint in changed packages, backwards-compat, error capture, docs, public-submodule check). No public-submodule or schema changes are involved here, so expect it to pass on lint + docs. Address anything it flags.

---

## Self-review notes

- **Spec coverage:** §1 backend parallelize → Task 1. §2 show-immediately + populate-in-place (extract fetch, `_MatchResult`, `_MatchLoadState`, `_MatchingProgress`, `onRefresh` branching) → Tasks 2–3. §3 friendly no-AI status messages → `_matchingStatusMessages` in Task 3 Step 2. Edge cases (fast response min-window, failure, no-matches, Back during loading) → Task 3 + Task 4 Step 1. Testing → Task 4.
- **Type consistency:** `_MatchResult` (`matches`, `failed`), `_MatchLoadState` (`future`, `result`), `_MatchingProgress(load:)`, `_ShowFocusMatches(... load:)`, `_buildFocusMatchesForm(... load:)` are used consistently across tasks. `_fetchMatches({description, title}) → Future<_MatchResult>` is defined in Task 2 and consumed in Task 3. `FormInfo` uses `builder:`; `FormToggle` uses `content:` — matched to the framework.
- **No placeholders:** every code step shows complete code; verification steps give exact commands and expected results.
```
