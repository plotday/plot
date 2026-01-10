import { createBrowserClient } from "@supabase/ssr";

/**
 * Parse a cookie string into key-value pairs
 */
function parseCookieString(str: string): Record<string, string> {
  return str
    .split(";")
    .map((v) => v.split("="))
    .reduce(
      (acc, [key, value]) => {
        if (key && value) {
          acc[decodeURIComponent(key.trim())] = decodeURIComponent(value.trim());
        }
        return acc;
      },
      {} as Record<string, string>,
    );
}

/**
 * Creates a Supabase client for browser-side operations with cookie-based storage
 * This client automatically stores PKCE code_verifier and session tokens in cookies
 *
 * Explicitly configures cookie handling for SSR compatibility to ensure the server
 * can read PKCE code verifiers stored during OAuth flows.
 */
export function createSupabaseBrowserClient(
  supabaseUrl: string,
  supabaseAnonKey: string,
) {
  return createBrowserClient(supabaseUrl, supabaseAnonKey, {
    cookies: {
      get(name: string) {
        if (typeof document === "undefined") return null;
        const cookies = parseCookieString(document.cookie);
        return cookies[name] || null;
      },
      set(name: string, value: string, options: any) {
        if (typeof document === "undefined") return;

        let cookieString = `${encodeURIComponent(name)}=${encodeURIComponent(value)}`;

        if (options?.maxAge) {
          cookieString += `; Max-Age=${options.maxAge}`;
        }
        if (options?.path) {
          cookieString += `; Path=${options.path}`;
        }
        if (options?.domain) {
          cookieString += `; Domain=${options.domain}`;
        }
        if (options?.sameSite) {
          cookieString += `; SameSite=${options.sameSite}`;
        }
        if (options?.secure) {
          cookieString += "; Secure";
        }

        document.cookie = cookieString;
      },
      remove(name: string, options: any) {
        if (typeof document === "undefined") return;

        let cookieString = `${encodeURIComponent(name)}=; Max-Age=0`;

        if (options?.path) {
          cookieString += `; Path=${options.path}`;
        }
        if (options?.domain) {
          cookieString += `; Domain=${options.domain}`;
        }

        document.cookie = cookieString;
      },
    },
  });
}
