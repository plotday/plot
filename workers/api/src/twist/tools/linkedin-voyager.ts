/**
 * Low-level Voyager API client used by both:
 *   1. The `POST /twist/:id/integrations/linkedin/cookie` endpoint, to probe
 *      the captured cookie and discover the connected user's profile.
 *   2. The built-in `LinkedIn` tool, to make all per-channel API calls.
 *
 * This module deliberately knows nothing about Plot — it's a thin transport
 * that handles the LinkedIn-specific request shape: the cookie pair, the
 * CSRF token derived from JSESSIONID, the `x-li-*` headers LinkedIn's web
 * client sends, and the pinned User-Agent. Higher-level concerns (rate
 * limiting, marking re-auth, transforming responses) live in the tool.
 */

import { createLogger } from "@plotday/worker-util";

const VOYAGER_BASE = "https://www.linkedin.com/voyager/api";

/**
 * The set of credentials needed to call Voyager on a user's behalf.
 *
 * `userAgent` is captured by the Plot client (in-app webview) the moment the
 * `li_at` cookie is harvested and then pinned to the connection. Reusing
 * exactly the User-Agent that was on the browser when the cookie was issued
 * is the single most important detection-evasion technique — LinkedIn
 * fingerprints sessions heavily and a mismatched fingerprint is one of the
 * faster ways to get a session invalidated.
 */
export type VoyagerCredentials = {
  liAt: string;
  jsessionid: string;
  userAgent: string;
};

/**
 * Thrown when a Voyager call comes back with an auth-style error (the cookie
 * was invalidated, the CSRF token went stale because the user signed out of
 * LinkedIn elsewhere, or LinkedIn returned a captcha/challenge response).
 *
 * The LinkedIn tool catches this and flags the connection for re-auth via
 * `integrations.markNeedsReauth`.
 */
export class VoyagerAuthError extends Error {
  constructor(
    message: string,
    public status: number
  ) {
    super(message);
    this.name = "VoyagerAuthError";
  }
}

/**
 * Make an authenticated Voyager call.
 *
 * - `cookie`/`csrf-token`/`User-Agent` reflect the captured session.
 * - `x-restli-protocol-version: 2.0.0` is required for the modern endpoints.
 * - `x-li-lang`, `x-li-track` mimic the headers the LinkedIn web client
 *   sends; without them many endpoints return empty bodies.
 * - `accept` requests the normalized JSON format used by Voyager (resolves
 *   referenced URNs inline, which is what every caller wants).
 *
 * Throws `VoyagerAuthError` on 401/403, a plain `Error` on other failures.
 */
export async function voyagerFetch(
  creds: VoyagerCredentials,
  path: string,
  init: { method?: string; body?: string; query?: Record<string, string> } = {}
): Promise<unknown> {
  const csrfToken = stripQuotes(creds.jsessionid);
  // LinkedIn stores JSESSIONID with surrounding double quotes; the cookie
  // value must keep them, the csrf-token header must not.
  const cookieJsession = csrfToken.includes('"')
    ? creds.jsessionid
    : `"${creds.jsessionid}"`;

  const query = init.query
    ? "?" +
      new URLSearchParams(init.query).toString()
    : "";
  const url = `${VOYAGER_BASE}${path}${query}`;

  const headers: Record<string, string> = {
    cookie: `li_at=${creds.liAt}; JSESSIONID=${cookieJsession}`,
    "csrf-token": csrfToken,
    "User-Agent": creds.userAgent,
    "x-restli-protocol-version": "2.0.0",
    "x-li-lang": "en_US",
    "x-li-track": JSON.stringify({
      clientVersion: "1.13.0",
      mpVersion: "1.13.0",
      osName: "web",
      timezoneOffset: 0,
      deviceFormFactor: "DESKTOP",
      mpName: "voyager-web",
    }),
    accept: "application/vnd.linkedin.normalized+json+2.1",
    "content-type": "application/json; charset=UTF-8",
  };

  const response = await fetch(url, {
    method: init.method ?? "GET",
    headers,
    body: init.body,
  });

  if (response.status === 401 || response.status === 403) {
    throw new VoyagerAuthError(
      `LinkedIn auth rejected (${response.status}) on ${path}`,
      response.status
    );
  }
  if (!response.ok) {
    const text = await response.text().catch(() => "");
    throw new Error(
      `Voyager call failed: ${response.status} on ${path}: ${text.slice(0, 200)}`
    );
  }

  // Some endpoints (mark-read, etc.) return empty bodies.
  const text = await response.text();
  if (!text) return null;
  try {
    return JSON.parse(text);
  } catch {
    throw new Error(`Voyager returned non-JSON body for ${path}`);
  }
}

function stripQuotes(s: string): string {
  return s.startsWith('"') && s.endsWith('"') ? s.slice(1, -1) : s;
}

/**
 * Probe the user's own profile to (a) confirm the captured cookie is valid
 * and (b) discover the URN, display name, and email needed to populate
 * `LinkedInProviderData`.
 *
 * Returns null when the call fails for any reason (invalid cookie, network
 * error, unexpected response shape) — callers turn this into a 401 for the
 * client.
 */
export async function probeLinkedInProfile(
  creds: VoyagerCredentials
): Promise<{
  userId: string;
  fullName: string;
  email: string | null;
} | null> {
  const logger = createLogger({ component: "linkedin-voyager", op: "probe" });
  let raw: unknown;
  try {
    raw = await voyagerFetch(creds, "/me");
  } catch (error) {
    logger.warn("Voyager /me probe threw", {
      message: (error as Error)?.message ?? String(error),
      status: (error as VoyagerAuthError)?.status,
    });
    return null;
  }
  if (!raw || typeof raw !== "object") {
    logger.warn("Voyager /me probe returned non-object body");
    return null;
  }

  // Voyager `/me` returns a normalized envelope with the calling member's
  // mini-profile under either `data.miniProfile` or `included[].$type ==
  // com.linkedin.voyager.identity.shared.MiniProfile`. We accept either to
  // tolerate the response-shape variation that has shipped over the years.
  const data = (raw as { data?: any; included?: any[] }).data ?? {};
  const included = (raw as { included?: any[] }).included ?? [];

  const mini =
    data.miniProfile ??
    included.find(
      (entry: any) =>
        entry?.$type ===
          "com.linkedin.voyager.identity.shared.MiniProfile" ||
        entry?.entityUrn?.startsWith?.("urn:li:fsd_profile:") ||
        entry?.entityUrn?.startsWith?.("urn:li:fs_miniProfile:")
    );

  if (!mini) {
    logger.warn(
      "Voyager /me probe: could not find a mini-profile in response envelope",
      {
        data_keys: Object.keys(data),
        included_count: included.length,
        included_types: included
          .slice(0, 10)
          .map((e: any) => e?.$type ?? "<no-type>"),
      }
    );
    return null;
  }

  // Normalize the URN to the modern `urn:li:fsd_profile:<id>` form.
  const rawUrn: string | undefined = mini.entityUrn ?? mini.dashEntityUrn;
  if (!rawUrn) {
    logger.warn("Voyager /me probe: mini-profile lacks entityUrn", {
      mini_keys: Object.keys(mini),
    });
    return null;
  }
  const userId = rawUrn.replace(
    /^urn:li:fs_miniProfile:/,
    "urn:li:fsd_profile:"
  );
  const firstName: string = mini.firstName ?? "";
  const lastName: string = mini.lastName ?? "";
  const fullName = `${firstName} ${lastName}`.trim() || mini.publicIdentifier;
  if (!fullName) {
    logger.warn("Voyager /me probe: mini-profile lacks first/last/public id");
    return null;
  }

  // `/me` does not return the user's email in modern responses; leaving null
  // is acceptable — the connector populates contacts from message
  // participants instead. If a future endpoint exposes the email reliably,
  // wire it in here.
  return { userId, fullName, email: null };
}
