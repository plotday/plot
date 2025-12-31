import { createBrowserClient } from "@supabase/ssr";

/**
 * Creates a Supabase client for browser-side operations with cookie-based storage
 * This client automatically stores PKCE code_verifier and session tokens in cookies
 */
export function createSupabaseBrowserClient(
  supabaseUrl: string,
  supabaseAnonKey: string,
) {
  return createBrowserClient(supabaseUrl, supabaseAnonKey);
}
