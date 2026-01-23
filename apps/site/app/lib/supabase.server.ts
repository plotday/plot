import { createServerClient, parseCookieHeader, serializeCookieHeader } from "@supabase/ssr";

export interface SupabaseEnv {
  SUPABASE_URL: string;
  SUPABASE_ANON_KEY: string;
}

/**
 * Creates a Supabase client for server-side operations with cookie storage
 * This automatically handles PKCE code_verifier storage and session token management
 */
export function createSupabaseServerClient(request: Request, env: SupabaseEnv) {
  const headers = new Headers();
  const isProduction = request.url.includes('plot.day');

  const supabase = createServerClient(env.SUPABASE_URL, env.SUPABASE_ANON_KEY, {
    cookies: {
      getAll() {
        return parseCookieHeader(request.headers.get("Cookie") ?? "")
          .filter((cookie): cookie is { name: string; value: string } => cookie.value !== undefined);
      },
      setAll(cookiesToSet) {
        cookiesToSet.forEach(({ name, value, options }) =>
          headers.append("Set-Cookie", serializeCookieHeader(name, value, {
            ...options,
            // Set cookies on root domain for cross-subdomain auth (plot.day <-> app.plot.day)
            domain: isProduction ? '.plot.day' : undefined,
          }))
        );
      },
    },
  });

  return { supabase, headers };
}

/**
 * Gets the current authenticated user from the request
 */
export async function getUser(request: Request, env: SupabaseEnv) {
  const { supabase, headers } = createSupabaseServerClient(request, env);

  // Get user from Supabase auth (will use cookies automatically)
  const {
    data: { user },
  } = await supabase.auth.getUser();

  return { user, headers };
}
