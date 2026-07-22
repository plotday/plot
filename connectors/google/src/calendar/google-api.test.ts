import { afterEach, describe, expect, it, vi } from "vitest";

import { ConferencingProvider } from "@plotday/twister";

import {
  containsHtml,
  extractConferencingLinks,
  GoogleApi,
  type GoogleEvent,
} from "./google-api";

/**
 * Stub the global `fetch` with a single canned Response and return the spy so
 * tests can assert on what was sent.
 */
function stubFetch(response: Response) {
  const spy = vi.fn(async () => response);
  vi.stubGlobal("fetch", spy);
  return spy;
}

describe("GoogleApi.call", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("treats 204 No Content as success (channels/stop)", async () => {
    // Google's channels/stop endpoint returns 204 with an empty body on
    // success. The call must NOT throw — a 204 is success, not an error.
    stubFetch(new Response(null, { status: 204 }));

    const api = new GoogleApi("token");
    const result = await api.call(
      "POST",
      "https://www.googleapis.com/calendar/v3/channels/stop",
      undefined,
      { id: "watch-id", resourceId: "resource-id" }
    );

    expect(result).toBeNull();
  });

  it("treats 200 with a JSON body as success and returns the parsed body", async () => {
    stubFetch(
      new Response(JSON.stringify({ items: [{ id: "cal-1" }] }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      })
    );

    const api = new GoogleApi("token");
    const result = await api.call(
      "GET",
      "https://www.googleapis.com/calendar/v3/users/me/calendarList"
    );

    expect(result).toEqual({ items: [{ id: "cal-1" }] });
  });

  it("returns null for 410 Gone", async () => {
    stubFetch(new Response("gone", { status: 410 }));

    const api = new GoogleApi("token");
    const result = await api.call("GET", "https://example.com");

    expect(result).toBeNull();
  });

  it("throws on a genuine server error", async () => {
    stubFetch(new Response("boom", { status: 500 }));

    const api = new GoogleApi("token");
    await expect(api.call("GET", "https://example.com")).rejects.toThrow(
      /HTTP 500/
    );
  });
});

describe("containsHtml", () => {
  it("detects real HTML tags", () => {
    expect(containsHtml("<div>hi</div>")).toBe(true);
    expect(containsHtml('<a href="https://x.com">link</a>')).toBe(true);
    expect(containsHtml("<br>")).toBe(true);
    expect(containsHtml("<br/>")).toBe(true);
    expect(containsHtml("line one<br>line two")).toBe(true);
    expect(containsHtml("<p>para</p>")).toBe(true);
  });

  it("does not treat angle-bracket autolinks as HTML", () => {
    // Outlook/Teams plaintext invites render links as `Label<https://url>` and
    // wrap bare URIs in angle brackets. These are NOT HTML tags and must route
    // through the plaintext markdown path, not the HTML converter.
    expect(containsHtml("Need help?<https://aka.ms/JoinTeamsMeeting>")).toBe(
      false
    );
    expect(containsHtml("<https://teams.microsoft.com/meet/123>")).toBe(false);
    expect(containsHtml("<tel:+15555555555,,111222333>")).toBe(false);
    expect(containsHtml("<mailto:someone@example.com>")).toBe(false);
  });

  it("classifies a full plaintext Teams invite as non-HTML", () => {
    expect(containsHtml(TEAMS_INVITE_DESCRIPTION)).toBe(false);
  });

  it("returns false for empty / nullish input", () => {
    expect(containsHtml(null)).toBe(false);
    expect(containsHtml(undefined)).toBe(false);
    expect(containsHtml("")).toBe(false);
    expect(containsHtml("just plain text")).toBe(false);
  });
});

/**
 * A representative Microsoft Teams meeting invite as Google Calendar stores it
 * in an event description: plain text (angle-bracket autolinks, ASCII separator
 * bars). All identifiers below are fabricated placeholders — no real data.
 */
const TEAMS_INVITE_DESCRIPTION = [
  "________________________________________________________________________________",
  "Microsoft Teams meeting",
  "Join on your computer, mobile app or room device",
  "Join: https://teams.microsoft.com/meet/1234567890?p=AbCdEfGhIj",
  "Meeting ID: 123 456 789 012",
  "Passcode: aB1cD2",
  "______________________________",
  "Need help?<https://aka.ms/JoinTeamsMeeting?omkt=en-US> | System reference<https://teams.microsoft.com/l/meetup-join/19%3ameeting_EXAMPLE%40thread.v2/0?context=%7b%22Tid%22%3a%22tenant-id%22%7d>",
  "Dial in by phone",
  "+1 555-555-5555,,111222333#<tel:+15555555555,,111222333> United States",
  "Find a local number<https://dialin.teams.microsoft.com/example?id=111222333>",
  "Phone conference ID: 111 222 333#",
  "Join on a video conferencing device",
  "Tenant key: example@m.webex.com",
  "Video ID: 111 222 333 44",
  "More info<https://www.webex.com/msteams?confid=1112223334&tenantkey=example&domain=m.webex.com>",
  "For organizers: Meeting options<https://teams.microsoft.com/meetingOptions/?organizerId=org-id&tenantId=tenant-id&threadId=19_meeting_EXAMPLE@thread.v2&messageId=0&language=en-US> | Reset dial-in PIN<https://dialin.teams.microsoft.com/usp/pstnconferencing>",
  "________________________________________________________________________________",
].join("\n");

function event(overrides: Partial<GoogleEvent>): GoogleEvent {
  return { id: "evt-1", ...overrides } as GoogleEvent;
}

describe("extractConferencingLinks", () => {
  it("keeps a single join link for a Teams invite, dropping non-join URLs", () => {
    const links = extractConferencingLinks(
      event({ description: TEAMS_INVITE_DESCRIPTION })
    );

    // The organizer /meetingOptions page, the webex.com/msteams device-gateway
    // page, and the dial-in local-number pages must all be dropped; the two
    // Teams join forms (/meet/ and /l/meetup-join/) collapse to one button.
    expect(links).toEqual([
      {
        url: "https://teams.microsoft.com/meet/1234567890?p=AbCdEfGhIj",
        provider: ConferencingProvider.microsoftTeams,
      },
    ]);
  });

  it("prefers a structured conferenceData video entry point", () => {
    const links = extractConferencingLinks(
      event({
        conferenceData: {
          entryPoints: [
            {
              entryPointType: "video",
              uri: "https://meet.google.com/abc-defg-hij",
            },
            { entryPointType: "phone", uri: "tel:+15555555555" },
          ],
        },
        description: "Join: https://meet.google.com/abc-defg-hij",
      })
    );

    expect(links).toEqual([
      {
        url: "https://meet.google.com/abc-defg-hij",
        provider: ConferencingProvider.googleMeet,
      },
    ]);
  });

  it("keeps one link per provider when several providers are present", () => {
    const links = extractConferencingLinks(
      event({
        description: [
          "Zoom: https://us02web.zoom.us/j/8888888888",
          "Backup zoom: https://us02web.zoom.us/j/9999999999",
          "Teams: https://teams.microsoft.com/meet/1234567890",
        ].join("\n"),
      })
    );

    expect(links).toEqual([
      {
        url: "https://us02web.zoom.us/j/8888888888",
        provider: ConferencingProvider.zoom,
      },
      {
        url: "https://teams.microsoft.com/meet/1234567890",
        provider: ConferencingProvider.microsoftTeams,
      },
    ]);
  });

  it("returns nothing when the description has only dial-in / options URLs", () => {
    const links = extractConferencingLinks(
      event({
        description: [
          "Find a local number<https://dialin.teams.microsoft.com/x?id=1>",
          "Meeting options<https://teams.microsoft.com/meetingOptions/?x=1>",
        ].join("\n"),
      })
    );

    expect(links).toEqual([]);
  });
});
