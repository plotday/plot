import type { Session } from "@supabase/supabase-js";
import { createClient } from "@supabase/supabase-js";

export interface SupabaseEnv {
  SUPABASE_URL: string;
  SUPABASE_ANON_KEY: string;
}

/**
 * Parse cookies from Cookie header string
 */
function parseCookies(cookieHeader: string): Record<string, string> {
  const cookies: Record<string, string> = {};
  if (!cookieHeader) return cookies;

  cookieHeader.split(";").forEach((cookie) => {
    const [name, ...rest] = cookie.trim().split("=");
    if (name && rest.length > 0) {
      cookies[name] = rest.join("=");
    }
  });
  return cookies;
}

/**
 * Gets the Supabase auth tokens from cookies
 */
function getAuthTokens(request: Request) {
  const cookieHeader = request.headers.get("Cookie") ?? "";
  const cookies = parseCookies(cookieHeader);

  // Supabase stores access token and refresh token in cookies
  const accessToken = cookies["sb-access-token"];
  const refreshToken = cookies["sb-refresh-token"];

  return { accessToken, refreshToken };
}

/**
 * Creates a Supabase client for server-side operations
 */
export function createSupabaseServerClient(request: Request, env: SupabaseEnv) {
  const { accessToken } = getAuthTokens(request);

  // Create client with global auth header if token exists
  const options = accessToken
    ? {
        global: {
          headers: {
            Authorization: `Bearer ${accessToken}`,
          },
        },
      }
    : {};

  const supabase = createClient(
    env.SUPABASE_URL,
    env.SUPABASE_ANON_KEY,
    options,
  );

  return { supabase, headers: new Headers() };
}

/**
 * Gets the current authenticated user from the request
 */
export async function getUser(request: Request, env: SupabaseEnv) {
  const { accessToken } = getAuthTokens(request);
  const supabase = createClient(env.SUPABASE_URL, env.SUPABASE_ANON_KEY);

  if (!accessToken) {
    return { user: null, headers: new Headers() };
  }

  // Verify the token by calling getUser with the access token
  const { data, error } = await supabase.auth.getClaims(accessToken);
  const user = data?.claims ?? null;

  if (error || !user) {
    return { user: null, headers: new Headers() };
  }

  return { user, headers: new Headers() };
}

/**
 * Creates Set-Cookie headers for authentication tokens
 * Note: Not using HttpOnly because browser needs access to refresh token (per Supabase docs)
 */
export function setAuthCookies(session: Session): string[] {
  const maxAge = 365 * 24 * 60 * 60; // 1 year in seconds
  const cookieOptions = `Max-Age=${maxAge}; Path=/; SameSite=Lax; Secure`;

  return [
    `sb-access-token=${session.access_token}; ${cookieOptions}`,
    `sb-refresh-token=${session.refresh_token}; ${cookieOptions}`,
  ];
}

/**
 * Creates Set-Cookie headers to clear authentication cookies
 */
export function clearAuthCookies(): string[] {
  const clearOptions = "Max-Age=0; Path=/; SameSite=Lax; Secure";

  return [
    `sb-access-token=; ${clearOptions}`,
    `sb-refresh-token=; ${clearOptions}`,
  ];
}
