import { vitePluginViteNodeMiniflare } from "@hiogawa/vite-node-miniflare";
import { reactRouter } from "@react-router/dev/vite";
import autoprefixer from "autoprefixer";
import postcssPresetMantine from "postcss-preset-mantine";
import postcssSimpleVars from "postcss-simple-vars";
import { defineConfig } from "vite";
import tsconfigPaths from "vite-tsconfig-paths";

export default defineConfig(({ isSsrBuild }) => ({
  build: {
    rollupOptions: isSsrBuild
      ? {
          input: "./workers/app.ts",
        }
      : undefined,
  },
  css: {
    postcss: {
      plugins: [
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
  ssr: {
    target: "webworker",
    noExternal: true,
    resolve: {
      conditions: ["worker", "workerd", "browser"],
    },
    optimizeDeps: {
      include: [
        "react",
        "react/jsx-runtime",
        "react/jsx-dev-runtime",
        "react-dom",
        "react-dom/server",
        "react-router",
      ],
    },
  },
  plugins: [
    vitePluginViteNodeMiniflare({
      entry: "./workers/app.ts",
      miniflareOptions: (options) => {
        options.compatibilityDate = "2024-11-18";
        options.compatibilityFlags = ["nodejs_compat"];
      },
    }),
    reactRouter(),
    tsconfigPaths(),
  ],
}));
