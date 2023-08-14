// createCookie is the preferred Remix method for creating cookies
// Raw cookies are used for the auth tokens because we want to manipulate the
// values without extra encoding or handling.
// import { createCookie } from "@remix-run/cloudflare";
import { parse as parseCookie, serialize as serializeCookie } from "cookie";

import { authCookieOptions } from "./auth";

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
  const auth = parseCookie(request.headers.get("Cookie") || "");
  response.headers.append(
    "Set-Cookie",
    serializeCookie("sa", auth.pa, tempCookieOptions)
  );
}

export function restoreAuthCookie(request: Request, response: Response) {
  const auth = parseCookie(request.headers.get("Cookie") || "");
  if (auth.sa?.length) {
    if (auth.sa !== auth.pa) {
      response.headers.append(
        "Set-Cookie",
        serializeCookie("pa", auth.sa, authCookieOptions)
      );
      return true;
    }
    response.headers.append(
      "Set-Cookie",
      serializeCookie("sa", "", tempCookieOptions)
    );
  }
  return false;
}
