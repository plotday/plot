import { defineConfig } from "vitest/config";

export default defineConfig({
  resolve: {
    // Resolve workspace connector packages from their TypeScript source
    // using the @plotday/connector export condition (same as the build path).
    conditions: ["@plotday/connector", "default"],
  },
  test: {},
});
