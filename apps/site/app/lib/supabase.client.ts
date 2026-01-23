import { createBrowserClient } from "@supabase/ssr";

/**
 * Creates a Supabase client for browser-side operations with cookie-based storage
 * This client automatically stores PKCE code_verifier and session tokens in cookies
 */
export function createSupabaseBrowserClient(
  supabaseUrl: string,
  supabaseAnonKey: string,
) {
  const isProduction = typeof window !== 'undefined' && window.location.hostname.endsWith('plot.day');

  return createBrowserClient(supabaseUrl, supabaseAnonKey, {
    // Set cookies on root domain for cross-subdomain auth (plot.day <-> app.plot.day)
    cookieOptions: isProduction ? { domain: '.plot.day', path: '/' } : undefined,
  });
}
