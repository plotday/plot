// createCookie is the preferred Remix method for creating cookies
// Raw cookies are used for the auth tokens because we want to manipulate the
// values without extra encoding or handling.
// import { createCookie } from "@remix-run/cloudflare";
import { parse as parseCookie, serialize as serializeCookie } from "cookie";

import type { SupabaseClient } from "app/db";

const SavedAuthKeyName = "plot-saved-auth";

const tempCookieOptions = {
  sameSite: false,
  secure: true,
  httpOnly: true,
  domain: "",
  path: "/",
};

export function saveCookie(response: Response, name: string, value: string) {
  response.headers.append(
    "Set-Cookie",
    serializeCookie(name, value, tempCookieOptions)
  );
}

export function getCookie(request: Request, name: string) {
  return parseCookie(request.headers.get("Cookie") || "")[name];
}

export function saveAuthCookie(request: Request, response: Response) {
  const cookies = parseCookie(request.headers.get("Cookie") || "");
  for (const key of Object.keys(cookies)) {
    if (!key.match(/^sb-.*auth-token$/)) continue;
    const value = cookies[key];
    response.headers.append(
      "Set-Cookie",
      serializeCookie(SavedAuthKeyName, value, tempCookieOptions)
    );
  }
}

export async function restoreSession(
  request: Request,
  response: Response,
  supabase: SupabaseClient
) {
  const cookies = parseCookie(request.headers.get("Cookie") || "");
  if (cookies[SavedAuthKeyName]?.length) {
    response.headers.append(
      "Set-Cookie",
      serializeCookie(SavedAuthKeyName, "", tempCookieOptions)
    );
    const auth = JSON.parse(cookies[SavedAuthKeyName]);
    const { access_token, refresh_token } = auth;
    if (access_token && refresh_token) {
      const { data, error } = await supabase.auth.setSession({
        access_token,
        refresh_token,
      });
      if (data?.session) return data.session;
      console.error(error);
    }
  }
  return null;
}
