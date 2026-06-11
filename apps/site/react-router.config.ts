import type { Config } from "@react-router/dev/config";

export default {
  // Config options...
  // Server-side render by default, to enable SPA mode set this to `false`
  ssr: true,
  future: {
    v8_viteEnvironmentApi: true,
    // v8_middleware is intentionally NOT enabled: the @cloudflare/vite-plugin
    // getLoadContext returns a plain { cloudflare: { env, ctx } } object, but
    // middleware mode requires a RouterContextProvider. Loaders read
    // context.cloudflare.env, so opting in needs a load-context migration first.
    v8_splitRouteModules: true,
    v8_passThroughRequests: true,
    v8_trailingSlashAwareDataRequests: true,
  },
} satisfies Config;
