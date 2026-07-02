import { RouterContextProvider, createRequestHandler } from "react-router";

import { cloudflareContext } from "../app/lib/cloudflare-context";

declare global {
  interface CloudflareEnvironment {
    CLERK_SECRET_KEY: string;
    CLERK_PUBLISHABLE_KEY: string;
    API_ROOT?: string;
    APP_ROOT?: string;
    POSTHOG_API_KEY?: string;
    POSTHOG_PROXY?: string;
    // Direct PostHog ingestion host for server-side exception capture. Defaults
    // to the US cloud. NOT POSTHOG_PROXY — that may route back through this very
    // worker, which is useless precisely when the worker is the thing failing.
    POSTHOG_HOST?: string;
    VOTES?: KVNamespace;
  }
}

// Note: `future.v8_middleware` (react-router.config.ts) makes loaders/actions
// receive a RouterContextProvider instead of a plain AppLoadContext; the
// Cloudflare bindings travel via cloudflareContext (app/lib/cloudflare-context).
// React Router's typegen declares the Future flag in .react-router/types.

const requestHandler = createRequestHandler(
  () => import("virtual:react-router/server-build"),
  import.meta.env.MODE,
);

// Marks a response that this handler produced because the worker itself threw
// (as opposed to a normal React Router 500 / ErrorBoundary render). The CI
// build-boot smoke gate (.github/workflows/build-site.yml) and the uptime
// monitor (.github/workflows/monitor-site.yml) both treat the presence of this
// header as a hard failure, so a broken bundle can never pass either check.
const WORKER_ERROR_HEADER = "x-plot-error";

// Best-effort, fire-and-forget report of a worker-level exception to PostHog.
// Never throws and never blocks the response — if PostHog is unreachable we
// still serve the error page. This is the server-side counterpart to the
// client-only PostHog snippet in root.tsx, which can't fire when the worker
// crashes before any client JS runs.
function reportWorkerException(
  env: CloudflareEnvironment,
  ctx: ExecutionContext,
  request: Request,
  error: unknown,
): void {
  const apiKey = env.POSTHOG_API_KEY;
  if (!apiKey) return;

  const err = error instanceof Error ? error : new Error(String(error));
  const host = (env.POSTHOG_HOST || "https://us.i.posthog.com").replace(/\/$/, "");
  const url = new URL(request.url);

  ctx.waitUntil(
    fetch(`${host}/capture/`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        api_key: apiKey,
        event: "site_worker_exception",
        distinct_id: "site-worker",
        properties: {
          name: err.name,
          message: err.message,
          stack: err.stack ?? null,
          path: url.pathname,
          host: url.host,
          method: request.method,
        },
      }),
    }).catch(() => {
      // Swallow — the error page must render regardless of PostHog reachability.
    }),
  );
}

function workerErrorResponse(): Response {
  const body = `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Plot — temporarily unavailable</title>
    <style>
      body { margin: 0; min-height: 100dvh; display: flex; align-items: center; justify-content: center;
             font-family: system-ui, -apple-system, sans-serif; background: #fff; color: #1a1a2e; }
      main { max-width: 28rem; padding: 2rem; text-align: center; }
      h1 { font-size: 1.5rem; margin: 0 0 0.5rem; }
      p { color: #6b6b80; line-height: 1.5; }
      a { color: #6741d9; }
    </style>
  </head>
  <body>
    <main>
      <h1>We'll be right back</h1>
      <p>Plot hit an unexpected error. Our team has been notified — please try again in a moment.</p>
    </main>
  </body>
</html>`;
  return new Response(body, {
    status: 503,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "retry-after": "30",
      "cache-control": "no-store",
      [WORKER_ERROR_HEADER]: "worker-exception",
    },
  });
}

export default {
  async fetch(request, env, ctx) {
    // Clerk SDK reads these from globalThis on Cloudflare Workers
    (globalThis as Record<string, unknown>).CLERK_SECRET_KEY = env.CLERK_SECRET_KEY;
    (globalThis as Record<string, unknown>).CLERK_PUBLISHABLE_KEY = env.CLERK_PUBLISHABLE_KEY;

    let response: Response;
    try {
      const context = new RouterContextProvider();
      context.set(cloudflareContext, { env, ctx });
      response = await requestHandler(request, context);
    } catch (error) {
      // A throw here is a worker-level failure (e.g. a bundling regression that
      // breaks module init, like the vite 8.1.0 Clerk `setErrorThrowerOptions`
      // crash). React Router handles most loader/render errors and returns a
      // 500 *response* instead of throwing, so reaching this catch means
      // something escaped the framework — log it (Cloudflare observability
      // captures console output), report it to PostHog, and serve a branded
      // page rather than the raw Cloudflare 1101 interstitial.
      console.error("[site worker] unhandled exception", error);
      reportWorkerException(env, ctx, request, error);
      return workerErrorResponse();
    }

    // Add CORS headers for static assets so they can be loaded cross-origin
    const url = new URL(request.url);
    if (url.pathname.startsWith("/assets/")) {
      const corsResponse = new Response(response.body, response);
      corsResponse.headers.set("Access-Control-Allow-Origin", "*");
      return corsResponse;
    }

    return response;
  },
} satisfies ExportedHandler<CloudflareEnvironment>;
