import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    globals: true,
    environment: "node",
    include: ["src/**/*.test.ts"],
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
        "./src/agent/__tests__/utils/cloudflare-workers-mock.ts",
        import.meta.url
      ).pathname,
    },
  },
});
