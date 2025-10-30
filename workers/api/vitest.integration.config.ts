import { defineWorkersProject } from "@cloudflare/vitest-pool-workers/config";

export default defineWorkersProject({
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
            "@supabase/realtime-js",
            "@supabase/supabase-js",
            "@plotday/db",
          ],
        },
      },
    },
    poolOptions: {
      workers: {
        isolatedStorage: false, // Required for WebSocket support (Supabase realtime)
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
