import { describe, expect, it } from "vitest";

import { plainTextToMarkdown } from "./thread-helpers";

describe("plainTextToMarkdown", () => {
  it("auto-links bare URLs", () => {
    const result = plainTextToMarkdown("Join: https://example.com");
    expect(result).toContain("[https://example.com](https://example.com)");
  });

  it("converts Outlook-style Label<url> into [Label](url)", () => {
    const input =
      "Manage Booking<https://outlook.office365.com/owa/calendar/ABC>";
    expect(plainTextToMarkdown(input)).toBe(
      "[Manage Booking](https://outlook.office365.com/owa/calendar/ABC)"
    );
  });

  it("shortens long auto-linked URLs to host/...", () => {
    const longUrl =
      "https://visit.teams.microsoft.com/webrtc-svc/api/route?tid=72f988bf-86f1-41af-91ab-2d7cd011db47&convId=19:meeting_ODI3MGJhNDItNzg0YS00ZDc3LWFhM2UtMGE3NGNiZTI3OGEx@thread.v2&oid=3ae81049";
    const result = plainTextToMarkdown(longUrl);
    expect(result).toBe(`[visit.teams.microsoft.com/...](${longUrl})`);
  });

  it("keeps short URLs as their full URL label", () => {
    const url = "https://example.com/path";
    expect(plainTextToMarkdown(url)).toBe(`[${url}](${url})`);
  });

  it("does not shorten URLs inside Label<url> links", () => {
    const input =
      "Join<https://visit.teams.microsoft.com/webrtc-svc/api/route?tid=72f988bf-86f1-41af-91ab-2d7cd011db47&convId=19:meeting_ODI3MGJhNDItNzg0YS00ZDc3LWFhM2UtMGE3NGNiZTI3OGEx>";
    const result = plainTextToMarkdown(input);
    expect(result).toMatch(/^\[Join\]\(https:\/\/visit\.teams[^)]+\)$/);
    expect(result).not.toContain("visit.teams.microsoft.com/...");
  });

  it("normalizes underscore bars to ---", () => {
    const input = "before\n________________________________\nafter";
    const result = plainTextToMarkdown(input);
    expect(result).toContain("---");
    expect(result).not.toContain("________________________________");
  });

  it("collapses consecutive HR lines into a single HR", () => {
    const input =
      "before\n________________________________\n\n________________________________\nafter";
    const result = plainTextToMarkdown(input);
    // The triple-bar pattern becomes a single ---
    const hrMatches = result.match(/^---$/gm) ?? [];
    expect(hrMatches.length).toBe(1);
  });

  it("doubles newlines so plaintext line breaks survive markdown rendering", () => {
    const input = "line 1\nline 2";
    expect(plainTextToMarkdown(input)).toBe("line 1\n\nline 2");
  });

  it("decodes common HTML entities", () => {
    expect(plainTextToMarkdown("a &amp; b")).toBe("a & b");
    expect(plainTextToMarkdown("&lt;tag&gt;")).toBe("<tag>");
  });

  it("handles the full Teams/Outlook calendar description realistically", () => {
    const input = [
      "Microsoft ISV Success",
      "",
      "",
      "Manage Booking<https://outlook.office365.com:443/owa/calendar/X/bookings/Y>",
      "",
      "Microsoft Teams meeting",
      "Join: https://teams.microsoft.com/meet/233362334498301?p=9ut5rs7oGhPeambZvb",
      "Meeting ID: 233 362 334 498 301",
      "Passcode: Lb2Ay6Ao",
      "________________________________",
      "",
      "________________________________",
      "For organisers",
      "Meeting options: https://teams.microsoft.com/meetingOptions/?organizerId=3ae81049-a0e8-4726-9453-65debe2ea39f&tenantId=72f988bf-86f1-41af-91ab-2d7cd011db47&threadId=19_meeting_ODI3MGJhNDItNzg0YS00ZDc3LWFhM2UtMGE3NGNiZTI3OGEx@thread.v2&messageId=0&language=en-US",
    ].join("\n");

    const result = plainTextToMarkdown(input);

    // Outlook label link converted
    expect(result).toContain(
      "[Manage Booking](https://outlook.office365.com:443/owa/calendar/X/bookings/Y)"
    );
    // Both long Teams URLs shortened; underlying href preserved
    expect(result).toContain(
      "[teams.microsoft.com/...](https://teams.microsoft.com/meet/233362334498301?p=9ut5rs7oGhPeambZvb)"
    );
    expect(result).toContain(
      "[teams.microsoft.com/...](https://teams.microsoft.com/meetingOptions/"
    );
    // Only one HR rendered despite two in the input
    const hrCount = (result.match(/^---$/gm) ?? []).length;
    expect(hrCount).toBe(1);
  });
});
