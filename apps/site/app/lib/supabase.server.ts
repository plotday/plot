import type { Session } from "@supabase/supabase-js";
import { createServerClient } from "@supabase/ssr";

export interface SupabaseEnv {
  SUPABASE_URL: string;
  SUPABASE_ANON_KEY: string;
}

/**
 * Parse cookies from Cookie header string
 * Decodes both cookie names and values to match browser encoding
 */
function parseCookies(cookieHeader: string): Record<string, string> {
  const cookies: Record<string, string> = {};
  if (!cookieHeader) return cookies;

  cookieHeader.split(";").forEach((cookie) => {
    const [name, ...rest] = cookie.trim().split("=");
    if (name && rest.length > 0) {
      try {
        const decodedName = decodeURIComponent(name.trim());
        const decodedValue = decodeURIComponent(rest.join("="));
        cookies[decodedName] = decodedValue;
      } catch (error) {
        // If decoding fails, store the raw values
        // This handles legacy cookies or malformed values gracefully
        cookies[name.trim()] = rest.join("=");
      }
    }
  });
  return cookies;
}

/**
 * Creates a Supabase client for server-side operations with cookie storage
 * This automatically handles PKCE code_verifier storage and session token management
 */
export function createSupabaseServerClient(request: Request, env: SupabaseEnv) {
  const cookieHeader = request.headers.get("Cookie") ?? "";
  const cookies = parseCookies(cookieHeader);
  const responseHeaders = new Headers();

  const supabase = createServerClient(env.SUPABASE_URL, env.SUPABASE_ANON_KEY, {
    cookies: {
      getAll() {
        return Object.entries(cookies).map(([name, value]) => ({ name, value }));
      },
      setAll(cookiesToSet) {
        cookiesToSet.forEach(({ name, value, options }) => {
          const cookieString = serializeCookie(name, value, options);
          responseHeaders.append("Set-Cookie", cookieString);
        });
      },
    },
  });

  return { supabase, headers: responseHeaders };
}

/**
 * Serialize a cookie with options
 */
function serializeCookie(
  name: string,
  value: string,
  options?: {
    maxAge?: number;
    path?: string;
    sameSite?: "lax" | "strict" | "none";
    secure?: boolean;
    httpOnly?: boolean;
  },
): string {
  const parts = [`${name}=${value}`];

  if (options?.maxAge !== undefined) {
    parts.push(`Max-Age=${options.maxAge}`);
  }
  if (options?.path) {
    parts.push(`Path=${options.path}`);
  }
  if (options?.sameSite) {
    parts.push(`SameSite=${options.sameSite.charAt(0).toUpperCase() + options.sameSite.slice(1)}`);
  }
  if (options?.secure) {
    parts.push("Secure");
  }
  if (options?.httpOnly) {
    parts.push("HttpOnly");
  }

  return parts.join("; ");
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

/**
 * Creates Set-Cookie headers for authentication tokens
 * @deprecated Use createSupabaseServerClient with @supabase/ssr instead - it handles cookies automatically
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
 * @deprecated Use createSupabaseServerClient with @supabase/ssr instead - it handles cookies automatically
 */
export function clearAuthCookies(): string[] {
  const clearOptions = "Max-Age=0; Path=/; SameSite=Lax; Secure";

  return [
    `sb-access-token=; ${clearOptions}`,
    `sb-refresh-token=; ${clearOptions}`,
  ];
}
