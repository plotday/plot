# Twist Builder: Version-Keyed Templates + In-Loop Typecheck — Design

**Date:** 2026-07-08
**Status:** Approved (brainstorming complete)
**Branch:** `twist-builder-fast-typecheck` (off main, post core#629/#635)

## Purpose

Two of the highest-leverage reliability/latency fixes for spec→twist generation, in one PR because they share the container subsystem:

1. **Kill `npm install` from the build hot path.** Today every build attempt runs a fresh `npm install` in `/tmp` (15–60s, the dominant build cost). Replace with pre-built, version-keyed dependency templates hardlink-copied per build.
2. **Typecheck inside the validation loop.** Today `plot build` is esbuild-only — type-broken twists (wrong SDK method names, bad argument shapes) pass "validation" and fail at runtime. Run `tsc --noEmit` alongside esbuild; failures feed the generator's retry loop as repairable error text.

Measured against the Gemini baseline (`evals/results/20260708-171348-baseline-gemini-31-pro-v2.json`: pipeline 100%, full pass 67%, 2 harness-level `typecheck_failed`).

## Decisions (from brainstorming)

1. **Version-keyed template cache.** The API sends the `@plotday/twister` version its prompt docs came from in each `/build` request; the container maintains per-version template dirs and always builds against that exact version. This closes the docs↔SDK drift class (previously: prompt docs from the API's bundled twister, build against whatever `latest` was at build time). First build after a version bump pays one install; all others skip install entirely.
2. **tsc + esbuild in parallel, merged errors.** A build succeeds only if both pass; failures return both error sets in one response so a retry fixes type and bundle errors in the same round trip. Rejected: tsc-first fail-fast (hides esbuild errors from the retry, costing extra LLM round trips); esbuild-only with advisory tsc (defeats the purpose).
3. **Defer container sharding.** With install gone, builds drop to ~3–10s; the single shared `"builder"` instance is unlikely to contend at current concurrency. Revisit with data from the comparison run.

## Non-goals

- No retry-loop, prompt, or streaming changes (PR B).
- No runtime smoke test of built modules (possible later addition to this subsystem).
- No container sharding (deferred, above).
- No changes to the `BuildResult` wire contract (`{success, module?, sourcemap?} | {success:false, errors}`) or to `TwistSource`.

## Changes

### Container server (`workers/api/containers/twist-builder/server/src/server.ts`)

- **Request shape:** `TwistSource` payload gains optional `twisterVersion?: string` (exact semver). Absent → resolve `"latest"` once per boot and use that version's template (backward compatible during rollout).
- **Template manager** (new module `server/src/templates.ts`):
  - `getTemplate(version: string): Promise<string>` returns the path of `/templates/<version>/` containing `package.json` (`{"dependencies": {"@plotday/twister": "<version>"}}`), installed `node_modules`, and a `tsconfig.json` extending `@plotday/twister/tsconfig.base.json` with `noEmit`, `declaration:false`, `declarationMap:false`, `sourceMap:false`, `include: ["src/**/*.ts"]`.
  - First request for a version runs `npm install` in the template dir; concurrent requests for the same version await one shared in-process promise (no duplicate installs). Failed installs remove the partial dir and reject.
  - Prune to the 4 most-recently-used versions (mtime-based) after each successful populate.
- **Per-build setup:** `cp -al <template>/node_modules <buildDir>/node_modules` plus copying `package.json`/`tsconfig.json` (hardlinks: ~100ms instead of 15–60s). Generated deps beyond `@plotday/twister` (rare) → write merged `package.json` and `npm install --no-audit --no-fund` the extras on top.
- **Build step:** run `tsc --noEmit -p <buildDir>` and `plot build` concurrently (Promise.all over promisified execs); await both.
  - Both pass → current success response (module + sourcemap).
  - Any fail → `{success:false, errors:[...]}` merging both: tsc output prefixed with the stable marker `Type check failed:` (first 80 diagnostic lines), esbuild failures keeping today's `Build failed:` prefix. Both included when both fail.
- **Image (`Dockerfile`):** pin `typescript` globally (tsc binary for builds); create `/templates`; keep the global `@plotday/twister` CLI install (still provides `plot build`).

### API worker (`workers/api/src/twist/builder.ts` + one small addition)

- POST body gains `twisterVersion` — the version of the API's own bundled `@plotday/twister` (the same package `getBuilderDocumentation()` reads). Mechanism resolved at plan time: `package.json` version import if the twister exports map allows it, else a build-time define; requirement is only that it equals the bundled docs version.
- No other changes: `BuildResult` handling, retries, and the generator are untouched — richer error text flows through existing plumbing.

### Eval harness (additive)

- `FailureClass` gains `build_typecheck`; `classifyBuildErrors` recognizes the `Type check failed:` marker (checked before the `build_bundle` default, after the npm/infra markers); classifier unit tests extended.
- No other harness changes — its level-4 `tsc` check remains the independent oracle that the container's in-loop typecheck actually worked.

## Error handling

- Template populate failure (registry down, bad version) → build fails with the npm-install marker (`Failed to install dependencies:` retained) → classified `build_npm_install`/infra as today.
- tsc crash (vs diagnostics) → non-zero exit with no parseable diagnostics still returns `Type check failed:` + raw output; never hangs the response (exec timeout 60s, matching the harness's own).
- Hardlink copy falls back to `cp -R` if the filesystem rejects `-l` (overlayfs quirk safety).

## Verification

1. Unit: classifier tests for `build_typecheck`; template-manager tests if the module is testable without Docker (pure-node fs logic — yes, with a fake installer hook).
2. Docker e2e (`builder.e2e.test.ts`, opt-in, extended): (a) type-error source → `success:false` with `Type check failed:` in errors; (b) valid source → success; (c) two sequential builds, same version → second reports no install (timing or a `X-Template-Cache: hit` response field); (d) extra-dep source still installs and builds.
3. **Comparison run** (~$5): `eval:twist-gen --label pr-a --runs 2 --compare evals/results/20260708-171348-baseline-gemini-31-pro-v2.json`. Expected: harness-level `typecheck_failed` → ~0 (moved in-loop: repaired → `pass`, or exhausted → `max_attempts_exhausted` w/ `build_typecheck`); mean `buildMs` per attempt drops from ~15–60s to ~3–10s; full-pass rate ≥ 67%.

## Success criteria

- No `npm install` on the hot path for twister-only twists (the overwhelming majority).
- Builds use exactly the twister version the prompt docs came from.
- Type-broken generations fail the build with actionable diagnostics instead of reaching users.
- Comparison run shows the expected taxonomy shift and build-time drop with no full-pass regression.
