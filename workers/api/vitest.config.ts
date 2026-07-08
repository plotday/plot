import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    globals: true,
    environment: "node",
    include: ["src/**/*.test.ts", "evals/**/*.test.ts"],
    exclude: ["src/**/__tests__/**/*.test.ts"], // Integration tests use separate config
    coverage: {
      provider: "v8",
      reporter: ["text", "json", "html"],
      exclude: ["**/__tests__/**", "**/*.test.ts"],
    },
  },
  resolve: {
    alias: {
      "cloudflare:workers": new URL(
        "./src/twist/__tests__/utils/cloudflare-workers-mock.ts",
        import.meta.url
      ).pathname,
      // Mirror the wrangler alias — defuddle's `exports` map doesn't include
      // ./markdown, so Vite (like esbuild without the alias) rejects the
      // deep import unless we redirect it explicitly.
      "defuddle/markdown": new URL(
        "./node_modules/defuddle/dist/markdown.js",
        import.meta.url
      ).pathname,
    },
  },
});
