import { describe, expect, it } from "vitest";
import { ActionType, ConferencingProvider, type Action } from "@plotday/twister/plot";
import {
  detectConferencingProvider,
  normalizeConferencingLink,
} from "./conferencing";

describe("detectConferencingProvider", () => {
  it("recognizes each known provider", () => {
    expect(detectConferencingProvider("https://us02web.zoom.us/j/123")).toBe(
      ConferencingProvider.zoom
    );
    expect(
      detectConferencingProvider("https://meet.google.com/abc-defg-hij")
    ).toBe(ConferencingProvider.googleMeet);
    expect(
      detectConferencingProvider("https://teams.microsoft.com/l/meetup-join/x")
    ).toBe(ConferencingProvider.microsoftTeams);
    expect(
      detectConferencingProvider("https://company.webex.com/meet/room")
    ).toBe(ConferencingProvider.webex);
  });

  it("returns null for a non-conferencing URL", () => {
    expect(detectConferencingProvider("https://example.com/page")).toBeNull();
  });
});

describe("normalizeConferencingLink", () => {
  it("collapses a location that is exactly a Zoom URL into a conferencing action and clears the location", () => {
    const url = "https://us02web.zoom.us/j/123456789?pwd=abc";
    const result = normalizeConferencingLink({
      meta: { location: url },
      actions: null,
    });
    // Location cleared (explicit null so the upsert meta-merge overwrites it).
    expect(result.meta?.location).toBeNull();
    // Conferencing action synthesized.
    const conf = result.actions?.find(
      (a) => a.type === ActionType.conferencing
    );
    expect(conf).toEqual({
      type: ActionType.conferencing,
      url,
      provider: ConferencingProvider.zoom,
    });
  });

  it("does not duplicate an action the connector already attached", () => {
    const url = "https://meet.google.com/abc-defg-hij";
    const existing: Action[] = [
      { type: ActionType.conferencing, url, provider: ConferencingProvider.googleMeet },
    ];
    const result = normalizeConferencingLink({
      meta: { location: url },
      actions: existing,
    });
    expect(result.meta?.location).toBeNull();
    expect(
      result.actions?.filter((a) => a.type === ActionType.conferencing).length
    ).toBe(1);
  });

  it("keeps a real physical location and surfaces the conferencing link separately", () => {
    const url = "https://zoom.us/j/999";
    const result = normalizeConferencingLink({
      meta: { location: `Room 5, ${url}` },
      actions: null,
    });
    expect(result.meta?.location).toBe("Room 5");
    expect(
      result.actions?.some((a) => a.type === ActionType.conferencing)
    ).toBe(true);
  });

  it("leaves a plain physical location untouched", () => {
    const input = { meta: { location: "123 Main St, Toronto" }, actions: null };
    const result = normalizeConferencingLink(input);
    expect(result).toBe(input); // unchanged reference
    expect(result.meta?.location).toBe("123 Main St, Toronto");
  });

  it("leaves a non-conferencing URL location untouched", () => {
    const input = { meta: { location: "https://example.com/where" }, actions: null };
    const result = normalizeConferencingLink(input);
    expect(result).toBe(input);
  });

  it("is a no-op when there is no location", () => {
    const input = { meta: { calendarId: "primary" }, actions: null };
    expect(normalizeConferencingLink(input)).toBe(input);
    const empty = { meta: null, actions: null };
    expect(normalizeConferencingLink(empty)).toBe(empty);
  });

  it("preserves other meta keys when clearing location", () => {
    const url = "https://zoom.us/j/1";
    const result = normalizeConferencingLink({
      meta: { location: url, calendarId: "primary", htmlLink: "https://cal" },
      actions: null,
    });
    expect(result.meta?.calendarId).toBe("primary");
    expect(result.meta?.htmlLink).toBe("https://cal");
    expect(result.meta?.location).toBeNull();
  });
});
