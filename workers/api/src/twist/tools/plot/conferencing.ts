import {
  ActionType,
  ConferencingProvider,
  type Action,
  type ThreadMeta,
} from "@plotday/twister/plot";

/**
 * Detects the videoconferencing provider for a URL. Single source of truth
 * for the server side — mirrors the connector-side heuristic in
 * `public/connectors/google-calendar/src/google-api.ts`. Returns null when
 * the URL doesn't match a known provider.
 */
export function detectConferencingProvider(
  url: string
): ConferencingProvider | null {
  const u = url.toLowerCase();
  if (u.includes("zoom.us")) return ConferencingProvider.zoom;
  if (u.includes("teams.microsoft.com") || u.includes("teams.live.com")) {
    return ConferencingProvider.microsoftTeams;
  }
  if (u.includes("webex.com")) return ConferencingProvider.webex;
  if (u.includes("meet.google.com")) return ConferencingProvider.googleMeet;
  return null;
}

// Matches URLs embedded in free text (mirrors the connector's extractor).
const URL_REGEX = /https?:\/\/[^\s<>"{}|\\^`[\]]+/gi;
// Separator punctuation/whitespace left dangling once a URL is removed from a
// location string (e.g. "Room 5, " -> "Room 5").
const LEADING_SEPARATORS = /^[\s,\-–—|·•]+/;
const TRAILING_SEPARATORS = /[\s,\-–—|·•]+$/;

/**
 * Reconciles a link's conferencing data so the same join link is never stored
 * both as a physical `meta.location` AND a conferencing action.
 *
 * Calendar events frequently carry the join link in BOTH places — e.g. a user
 * pastes a Zoom URL into Google Calendar's "location" field, which the
 * connector also detects and exposes as a {@link ActionType.conferencing}
 * action. Persisting both makes clients render the link twice: once as a tidy
 * provider chip and once as raw, unclickable URL text mislabelled as a
 * physical location.
 *
 * When the location text *is* (or contains) a recognised videoconferencing
 * URL, this:
 *  1. ensures a conferencing action exists for that URL (synthesising one when
 *     the connector didn't attach it), and
 *  2. strips the conferencing URL(s) out of `meta.location`, leaving any real
 *     physical location (a room, an address) intact.
 *
 * `location` is set to `null` rather than deleted: `upsert_link` MERGES `meta`
 * (`existing || incoming`), so omitting the key would preserve a previously
 * stored URL. An explicit `null` overwrites it.
 *
 * Pure and idempotent — returns the (possibly new) `meta`/`actions`; the
 * inputs are not mutated.
 */
export function normalizeConferencingLink(input: {
  meta?: ThreadMeta | null;
  actions?: Action[] | null;
}): { meta?: ThreadMeta | null; actions?: Action[] | null } {
  const meta = input.meta;
  const rawLocation =
    typeof meta?.location === "string" ? meta.location.trim() : null;
  if (!rawLocation) return input;

  const confUrls = (rawLocation.match(URL_REGEX) ?? []).filter(
    (url) => detectConferencingProvider(url) !== null
  );
  if (confUrls.length === 0) return input;

  // Ensure a conferencing action exists for each detected join URL.
  const actions: Action[] = [...(input.actions ?? [])];
  for (const url of confUrls) {
    const exists = actions.some(
      (a) => a.type === ActionType.conferencing && a.url === url
    );
    if (!exists) {
      actions.push({
        type: ActionType.conferencing,
        url,
        provider: detectConferencingProvider(url)!,
      });
    }
  }

  // Strip the join URL(s) from the location so the same link isn't stored
  // twice. Preserve any leftover physical location (room name, address).
  let residual = rawLocation;
  for (const url of confUrls) residual = residual.split(url).join("");
  residual = residual
    .replace(LEADING_SEPARATORS, "")
    .replace(TRAILING_SEPARATORS, "")
    .trim();

  const newMeta: ThreadMeta = {
    ...(meta ?? {}),
    location: residual.length > 0 ? residual : null,
  };

  return { meta: newMeta, actions };
}
