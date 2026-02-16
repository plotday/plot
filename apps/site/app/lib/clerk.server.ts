/**
 * Sets Clerk environment variables on globalThis for Cloudflare Workers,
 * where process.env is not available.
 */
export function initClerkEnv(env: {
  CLERK_SECRET_KEY: string;
  CLERK_PUBLISHABLE_KEY: string;
}) {
  (globalThis as Record<string, unknown>).CLERK_SECRET_KEY = env.CLERK_SECRET_KEY;
  (globalThis as Record<string, unknown>).CLERK_PUBLISHABLE_KEY =
    env.CLERK_PUBLISHABLE_KEY;
}
