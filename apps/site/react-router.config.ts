import type { Config } from "@react-router/dev/config";

export default {
  // Config options...
  // Server-side render by default, to enable SPA mode set this to `false`
  ssr: true,
  future: {
    v8_viteEnvironmentApi: true,
    // Required by @clerk/react-router v3 (clerkMiddleware). The worker entry
    // (workers/app.ts) builds a RouterContextProvider and loaders read the
    // Cloudflare bindings via context.get(cloudflareContext) — see
    // app/lib/cloudflare-context.ts.
    v8_middleware: true,
    v8_splitRouteModules: true,
    v8_passThroughRequests: true,
    v8_trailingSlashAwareDataRequests: true,
  },
} satisfies Config;
