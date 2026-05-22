import { fileURLToPath } from "node:url";

import { defineWorkersProject } from "@cloudflare/vitest-pool-workers/config";

export default defineWorkersProject({
  // `defuddle/markdown` isn't in defuddle's package.json exports map (see
  // workers/api/wrangler.jsonc for the matching deploy-time alias). The
  // wrangler alias isn't propagated by `unstable_getMiniflareWorkerOptions`,
  // so we point vite at the deep import directly; the optimizer entries
  // below pre-bundle defuddle/markdown and turndown as ESM so workerd can
  // load them (markdown.js is CommonJS and turndown's `require` calls need
  // to be resolved at bundle time).
  resolve: {
    alias: {
      "defuddle/markdown": fileURLToPath(
        new URL("./node_modules/defuddle/dist/markdown.js", import.meta.url),
      ),
    },
  },
  test: {
    globals: true,
    include: ["src/**/__tests__/**/*.test.ts"],
    coverage: {
      provider: "v8",
      reporter: ["text", "json", "html"],
      exclude: ["**/__tests__/**", "**/*.test.ts"],
    },
    deps: {
      optimizer: {
        ssr: {
          enabled: true,
          include: [
            "websocket",
            "@plotday/db",
            "defuddle/markdown",
            "turndown",
          ],
        },
      },
    },
    poolOptions: {
      workers: {
        isolatedStorage: false, // Required for WebSocket support
        singleWorker: true, // Use single worker for all tests when storage is shared
        wrangler: {
          // Use test-specific configuration without containers
          configPath: "./wrangler.test.jsonc",
        },
        miniflare: {
          // Note: worker_loaders not yet supported in vitest-pool-workers
          // Tests use the `module` parameter instead
        },
      },
    },
  },
});
