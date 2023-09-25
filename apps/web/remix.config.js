/** @type {import('@remix-run/dev').AppConfig} */
export default {
  devServerBroadcastDelay: 1000,
  ignoredRouteFiles: ["**/.*", "**/*.css"],
  server: "./server.ts",
  serverBuildPath: "functions/[[path]].js",
  serverConditions: ["worker"],
  serverDependenciesToBundle: "all",
  serverMainFields: ["browser", "module", "main"],
  serverMinify: true,
  serverModuleFormat: "esm",
  serverPlatform: "neutral",
  serverNodeBuiltinsPolyfill: {
    modules: {
      process: true,
    },
  },
  watchPaths: [
    "./node_modules/@plotday/db/src/**",
    "./node_modules/@plotday/cal/src/**",
    "./node_modules/@plotday/tz/src/**",
    "./node_modules/@plotday/worker-request/src/**",
  ],
  postcss: true,
  future: {},
};
