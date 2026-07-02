import { createContext } from "react-router";

/**
 * Typed router context slot for the Cloudflare bindings. With React Router's
 * `v8_middleware` future flag enabled (required by @clerk/react-router v3's
 * clerkMiddleware), loaders no longer receive a plain `AppLoadContext` object —
 * they receive a `RouterContextProvider`, and values must be read through
 * context objects like this one.
 *
 * The worker entry (workers/app.ts) sets this on every request:
 *   context.set(cloudflareContext, { env, ctx });
 * Loaders/actions read it with:
 *   const { env } = context.get(cloudflareContext);
 */
export const cloudflareContext = createContext<{
  env: CloudflareEnvironment;
  ctx: ExecutionContext;
}>();
