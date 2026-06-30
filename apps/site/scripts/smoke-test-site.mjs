#!/usr/bin/env node
// Smoke test for the marketing site (apps/site) — the React Router SSR worker
// served at plot.day.
//
// Detects worker-level failures: a bundling regression that crashes the worker
// at module init (e.g. the vite 8.1.0 Clerk `setErrorThrowerOptions is not
// defined` crash that took plot.day down site-wide) surfaces here as either an
// `x-plot-error` response header (set by workers/app.ts when it catches a
// worker-level throw) or the raw Cloudflare "Worker threw exception" 1101
// interstitial. Both are hard failures.
//
// Used by:
//   - .github/workflows/build-site.yml  — boots the freshly-built worker and
//     points this at it BEFORE deploy, so a broken bundle fails the PR check.
//   - .github/workflows/monitor-site.yml — runs against https://plot.day on a
//     schedule and reports to PostHog on failure.
//
// Usage:
//   node smoke-test-site.mjs --url https://plot.day                # strict: expect 200
//   node smoke-test-site.mjs --url http://127.0.0.1:8788 --no-status-check
//                                          # worker-health only (no Clerk keys)
//   node smoke-test-site.mjs --url <base> --route / --route /pricing --expect-status 200
//
// Exit code 0 = healthy, 1 = a check failed. No third-party dependencies
// (relies on global fetch — Node 18+).

const DEFAULT_ROUTES = ["/", "/pricing"];
const TIMEOUT_MS = Number(process.env.SMOKE_TIMEOUT_MS ?? 20_000);

// Header set by workers/app.ts when it catches a worker-level throw.
const WORKER_ERROR_HEADER = "x-plot-error";

// Substrings in the response body that indicate the worker crashed rather than
// rendered. The Cloudflare 1101 interstitial and common bundling errors.
const FATAL_BODY_MARKERS = [
  "Worker threw exception",
  "Error 1101",
  "is not defined", // dangling-reference bundling bugs (the one this guards against)
];

function parseArgs(argv) {
  const out = { url: null, routes: [], expectStatus: 200, statusCheck: true };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--url") out.url = argv[++i];
    else if (a.startsWith("--url=")) out.url = a.slice("--url=".length);
    else if (a === "--route") out.routes.push(argv[++i]);
    else if (a.startsWith("--route=")) out.routes.push(a.slice("--route=".length));
    else if (a === "--expect-status") out.expectStatus = Number(argv[++i]);
    else if (a.startsWith("--expect-status=")) out.expectStatus = Number(a.slice("--expect-status=".length));
    else if (a === "--no-status-check") out.statusCheck = false;
  }
  if (out.routes.length === 0) out.routes = DEFAULT_ROUTES;
  return out;
}

async function checkRoute(base, route, { expectStatus, statusCheck }) {
  const target = new URL(route, base).toString();
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  let res;
  try {
    res = await fetch(target, {
      signal: controller.signal,
      headers: { "user-agent": "plot-site-smoke-test" },
    });
  } catch (err) {
    return { target, ok: false, reason: `request failed: ${err?.message ?? err}` };
  } finally {
    clearTimeout(timer);
  }

  if (res.headers.has(WORKER_ERROR_HEADER)) {
    return {
      target,
      ok: false,
      reason: `worker-level failure: ${WORKER_ERROR_HEADER}=${res.headers.get(WORKER_ERROR_HEADER)} (status ${res.status})`,
    };
  }

  const body = await res.text().catch(() => "");
  const marker = FATAL_BODY_MARKERS.find((m) => body.includes(m));
  if (marker) {
    return { target, ok: false, reason: `worker crash marker in body: "${marker}" (status ${res.status})` };
  }

  // Status assertion is opt-out. The CI build-boot gate runs with
  // --no-status-check because it boots the worker with placeholder Clerk keys,
  // so a *rendered* 500 (bad-key ErrorBoundary) is expected and is NOT a worker
  // crash — only x-plot-error / body markers indicate the bundling failures
  // this guards against. The prod monitor keeps the check on (expects 200).
  if (statusCheck && res.status !== expectStatus) {
    return { target, ok: false, reason: `expected HTTP ${expectStatus}, got ${res.status}` };
  }

  return { target, ok: true, reason: `HTTP ${res.status}` };
}

async function main() {
  const { url, routes, expectStatus, statusCheck } = parseArgs(process.argv.slice(2));
  if (!url) {
    console.error("smoke-test-site: --url <base> is required");
    process.exit(2);
  }

  console.log(`Smoke-testing ${url} (routes: ${routes.join(", ")}; status check: ${statusCheck ? expectStatus : "off"})`);

  const results = [];
  for (const route of routes) {
    const r = await checkRoute(url, route, { expectStatus, statusCheck });
    console.log(`  ${r.ok ? "✓" : "✗"} ${r.target} — ${r.reason}`);
    results.push(r);
  }

  const failures = results.filter((r) => !r.ok);
  if (failures.length > 0) {
    console.error(`\nSmoke test FAILED: ${failures.length}/${results.length} route(s) unhealthy.`);
    process.exit(1);
  }
  console.log(`\nSmoke test passed: ${results.length}/${results.length} route(s) healthy.`);
}

main().catch((err) => {
  console.error("smoke-test-site: unexpected error", err);
  process.exit(1);
});
