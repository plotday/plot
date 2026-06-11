import { cloudflare } from "@cloudflare/vite-plugin";
import { reactRouter } from "@react-router/dev/vite";
import autoprefixer from "autoprefixer";
import postcssPresetMantine from "postcss-preset-mantine";
import postcssSimpleVars from "postcss-simple-vars";
import tailwindcss from "tailwindcss";
import { defineConfig, type UserConfig } from "vite";
import tsconfigPaths from "vite-tsconfig-paths";

export default defineConfig(() => ({
  css: {
    postcss: {
      plugins: [
        tailwindcss,
        autoprefixer,
        postcssPresetMantine,
        postcssSimpleVars({
          variables: {
            "mantine-breakpoint-xs": "36em",
            "mantine-breakpoint-sm": "48em",
            "mantine-breakpoint-md": "62em",
            "mantine-breakpoint-lg": "75em",
            "mantine-breakpoint-xl": "88em",
          },
        }),
      ],
    },
  },
  optimizeDeps: {
    include: [
      "react",
      "react/jsx-runtime",
      "react/jsx-dev-runtime",
      "react-dom",
      "react-dom/client",
      "react-router",
    ],
  },
  ssr: {
    target: "webworker",
    noExternal: true,
    optimizeDeps: {
      // Pre-bundle the server-only Clerk subpaths at startup. Without this,
      // `@clerk/react-router/api.server` (imported only from
      // internal-auth.server.ts, reachable only via /internal) is discovered
      // lazily on the first /internal request, triggering a mid-request SSR
      // re-optimization and the "new version of the pre-bundle" error.
      include: [
        "@clerk/react-router",
        "@clerk/react-router/api.server",
        "@clerk/react-router/ssr.server",
      ],
    },
    resolve: {
      conditions: ["workerd", "worker", "browser"],
      externalConditions: ["workerd", "worker"],
    },
  },
  plugins: [
    cloudflare({ viteEnvironment: { name: "ssr" } }),
    reactRouter(),
    tsconfigPaths({ projects: ["tsconfig.json"] }),
  ],
}) satisfies UserConfig);
