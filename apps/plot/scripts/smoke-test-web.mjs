#!/usr/bin/env node
// Smoke test for the Flutter web build.
//
// Loads the app in a headless Chromium and asserts that it boots: either the
// `#splash` element is removed (success — RootProvider mounted), or the
// `Failed to start Plot.` ErrorApp renders (failure). A timeout with neither
// condition met is also treated as failure.
//
// Usage:
//   node smoke-test-web.mjs --dir build/web              # serve a build dir
//   node smoke-test-web.mjs --url https://app.plot.day   # test a deployed URL
//
// Requires `playwright` resolvable from Node (CI installs it ad-hoc).

import { chromium } from "playwright";
import { createServer } from "node:http";
import { readFile, stat, writeFile, mkdir } from "node:fs/promises";
import { dirname, join, normalize, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const APP_ROOT = resolve(SCRIPT_DIR, "..");

const TIMEOUT_MS = Number(process.env.SMOKE_TIMEOUT_MS ?? 60_000);
const FAILURE_TEXT = "Failed to start Plot.";

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "application/javascript; charset=utf-8",
  ".mjs": "application/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".webp": "image/webp",
  ".ico": "image/x-icon",
  ".wasm": "application/wasm",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
  ".ttf": "font/ttf",
  ".otf": "font/otf",
  ".map": "application/json; charset=utf-8",
};

function parseArgs(argv) {
  const out = { dir: null, url: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--dir") out.dir = argv[++i];
    else if (a === "--url") out.url = argv[++i];
    else if (a.startsWith("--dir=")) out.dir = a.slice("--dir=".length);
    else if (a.startsWith("--url=")) out.url = a.slice("--url=".length);
  }
  if (!out.dir && !out.url) out.dir = "build/web";
  return out;
}

async function startStaticServer(rootDir) {
  const root = resolve(rootDir);
  const rootStat = await stat(root).catch(() => null);
  if (!rootStat?.isDirectory()) {
    throw new Error(`Build directory not found: ${root}`);
  }

  const server = createServer(async (req, res) => {
    try {
      // Reject anything with `..` after normalization (path traversal guard).
      const urlPath = decodeURIComponent((req.url ?? "/").split("?")[0]);
      let relPath = normalize(urlPath).replace(/^\/+/, "");
      if (relPath === "" || relPath.endsWith("/")) relPath += "index.html";
      const filePath = resolve(root, relPath);
      if (!filePath.startsWith(root)) {
        res.writeHead(403).end("Forbidden");
        return;
      }
      const s = await stat(filePath).catch(() => null);
      const target = s?.isDirectory()
        ? resolve(filePath, "index.html")
        : filePath;
      const data = await readFile(target);
      const ext = target.slice(target.lastIndexOf("."));
      res.writeHead(200, {
        "content-type": MIME[ext] ?? "application/octet-stream",
        // Match production (apps/plot/web/_headers) so we exercise the same
        // popup/postMessage behaviour the deployed site does.
        "cross-origin-opener-policy": "same-origin-allow-popups",
      });
      res.end(data);
    } catch (err) {
      res.writeHead(404).end(`Not found: ${req.url}`);
    }
  });

  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const address = server.address();
  const port = typeof address === "object" && address ? address.port : 0;
  return {
    url: `http://127.0.0.1:${port}/`,
    close: () => new Promise((r) => server.close(() => r())),
  };
}

async function runTest({ targetUrl, label }) {
  const consoleErrors = [];
  const pageErrors = [];
  const failedRequests = [];
  const allConsole = [];

  const browser = await chromium.launch();
  const context = await browser.newContext({
    viewport: { width: 1280, height: 800 },
    locale: "en-US",
  });
  const page = await context.newPage();

  page.on("console", (msg) => {
    const entry = { type: msg.type(), text: msg.text() };
    allConsole.push(entry);
    if (msg.type() === "error") consoleErrors.push(entry);
  });
  page.on("pageerror", (err) => {
    pageErrors.push({ message: err.message, stack: err.stack });
  });
  page.on("requestfailed", (req) => {
    failedRequests.push({
      url: req.url(),
      failure: req.failure()?.errorText ?? "unknown",
    });
  });

  console.log(`[smoke] ${label}: navigating to ${targetUrl}`);
  const navStart = Date.now();
  try {
    await page.goto(targetUrl, {
      waitUntil: "domcontentloaded",
      timeout: 30_000,
    });
  } catch (err) {
    await dumpFailure({
      page,
      label,
      reason: `navigation failed: ${err.message}`,
      consoleErrors,
      pageErrors,
      failedRequests,
      allConsole,
    });
    await browser.close();
    return false;
  }

  // Race success vs. failure conditions, with a timeout. Each leg gets a
  // tail `.catch` so the losing leg's eventual rejection (when the other
  // resolves first, or when the page navigates away) does not surface as an
  // unhandled rejection.
  const splashGone = page
    .waitForFunction(() => !document.getElementById("splash"), null, {
      timeout: TIMEOUT_MS,
      polling: 200,
    })
    .then(() => "started")
    .catch(() => null);

  const errorAppShown = page
    .waitForFunction(
      (text) => document.body && document.body.innerText.includes(text),
      FAILURE_TEXT,
      { timeout: TIMEOUT_MS, polling: 200 }
    )
    .then(() => "error_app")
    .catch(() => null);

  // Whichever resolves first wins; if both end up null (both timed out), we
  // treat that as a timeout failure.
  const first = await Promise.race([
    splashGone,
    errorAppShown,
    new Promise((r) => setTimeout(() => r(null), TIMEOUT_MS + 1000)),
  ]);
  const outcome = first ?? "timeout";

  const elapsedMs = Date.now() - navStart;

  if (outcome === "started") {
    console.log(`[smoke] ${label}: started OK in ${elapsedMs}ms`);
    if (consoleErrors.length > 0) {
      console.warn(
        `[smoke] ${label}: app started but had ${consoleErrors.length} console error(s):`
      );
      for (const e of consoleErrors.slice(0, 10)) {
        console.warn(`  - ${e.text}`);
      }
    }
    await browser.close();
    return true;
  }

  let reason;
  if (outcome === "error_app") {
    const errorText = await page
      .evaluate(() => document.body?.innerText ?? "")
      .catch(() => "");
    reason = `ErrorApp rendered (${FAILURE_TEXT}): ${errorText
      .split("\n")
      .slice(0, 6)
      .join(" | ")}`;
  } else {
    reason = `Timed out after ${TIMEOUT_MS}ms — splash never removed and no ErrorApp shown`;
  }

  await dumpFailure({
    page,
    label,
    reason,
    consoleErrors,
    pageErrors,
    failedRequests,
    allConsole,
  });
  await browser.close();
  return false;
}

async function dumpFailure({
  page,
  label,
  reason,
  consoleErrors,
  pageErrors,
  failedRequests,
  allConsole,
}) {
  console.error(`\n[smoke] ❌ ${label}: ${reason}\n`);

  if (pageErrors.length > 0) {
    console.error(`[smoke] ${pageErrors.length} page error(s):`);
    for (const e of pageErrors.slice(0, 10)) {
      console.error(`  - ${e.message}`);
      if (e.stack) console.error(e.stack.split("\n").slice(0, 8).join("\n"));
    }
  }

  if (consoleErrors.length > 0) {
    console.error(`\n[smoke] ${consoleErrors.length} console error(s):`);
    for (const e of consoleErrors.slice(0, 20)) {
      console.error(`  - ${e.text}`);
    }
  }

  if (failedRequests.length > 0) {
    console.error(`\n[smoke] ${failedRequests.length} failed request(s):`);
    for (const r of failedRequests.slice(0, 20)) {
      console.error(`  - ${r.failure}: ${r.url}`);
    }
  }

  if (allConsole.length > 0) {
    console.error(`\n[smoke] last ${Math.min(allConsole.length, 30)} console message(s):`);
    for (const e of allConsole.slice(-30)) {
      console.error(`  [${e.type}] ${e.text}`);
    }
  }

  // Best-effort artifact capture for CI.
  try {
    const outDir = resolve(APP_ROOT, "build", "smoke-test");
    await mkdir(outDir, { recursive: true });
    const safeLabel = label.replace(/[^a-z0-9_-]+/gi, "_");
    const screenshotPath = join(outDir, `${safeLabel}.png`);
    const htmlPath = join(outDir, `${safeLabel}.html`);
    await page.screenshot({ path: screenshotPath, fullPage: true });
    const html = await page.content();
    await writeFile(htmlPath, html);
    console.error(`\n[smoke] artifacts: ${screenshotPath}, ${htmlPath}`);
  } catch (err) {
    console.error(`[smoke] failed to capture artifacts: ${err.message}`);
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));

  let targetUrl;
  let server = null;
  let label;

  if (args.url) {
    targetUrl = args.url;
    label = args.url;
  } else {
    server = await startStaticServer(args.dir);
    targetUrl = server.url;
    label = `local:${args.dir}`;
  }

  let ok = false;
  try {
    ok = await runTest({ targetUrl, label });
  } finally {
    if (server) await server.close();
  }

  process.exit(ok ? 0 : 1);
}

main().catch((err) => {
  console.error("[smoke] unexpected error:", err);
  process.exit(2);
});
