import { defineConfig } from "vitest/config";

export default defineConfig({
  resolve: {
    conditions: ["@plotday/connector", "default"],
  },
  test: {},
});
