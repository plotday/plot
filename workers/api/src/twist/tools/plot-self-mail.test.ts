import { describe, expect, it } from "vitest";

import type { NewLinkWithNotes } from "@plotday/twister/plot";

import { PLOT_SENDING_DOMAINS, isPlotSelfMail, linkSenderEmail } from "./plot-self-mail";

// Minimal NewLinkWithNotes builders. Only the fields the helper reads matter.
const link = (over: Partial<NewLinkWithNotes>): NewLinkWithNotes =>
  ({ type: "email", ...over }) as NewLinkWithNotes;

describe("isPlotSelfMail", () => {
  it("flags Plot's own sign-in mail (link author on the sending subdomain)", () => {
    expect(
      isPlotSelfMail(link({ author: { email: "noreply@updates.plot.day", name: "Plot" } }))
    ).toBe(true);
  });

  it("flags Plot's info@ transactional sender too", () => {
    expect(
      isPlotSelfMail(link({ author: { email: "info@updates.plot.day", name: "Plot" } }))
    ).toBe(true);
  });

  it("matches the sending domain case-insensitively", () => {
    expect(
      isPlotSelfMail(link({ author: { email: "NoReply@Updates.Plot.Day", name: "Plot" } }))
    ).toBe(true);
  });

  it("does NOT flag a real Plot user on plot.day (team / human mailbox)", () => {
    expect(
      isPlotSelfMail(link({ author: { email: "kris@plot.day", name: "Kris Braun" } }))
    ).toBe(false);
  });

  it("does NOT flag the team reply-to address (team@plot.day)", () => {
    expect(
      isPlotSelfMail(link({ author: { email: "team@plot.day", name: "Plot" } }))
    ).toBe(false);
  });

  it("does NOT flag an external sender", () => {
    expect(
      isPlotSelfMail(link({ author: { email: "someone@gmail.com", name: "Someone" } }))
    ).toBe(false);
  });

  it("falls back to the first note's author when the link has no author", () => {
    expect(
      isPlotSelfMail(
        link({ author: undefined, notes: [{ author: { email: "noreply@updates.plot.day" } }] })
      )
    ).toBe(true);
  });

  it("returns false when the sender is an existing actor id (no email)", () => {
    expect(isPlotSelfMail(link({ author: { id: "actor-1" as never } }))).toBe(false);
  });

  it("returns false when there is no author or notes at all", () => {
    expect(isPlotSelfMail(link({}))).toBe(false);
  });
});

describe("linkSenderEmail", () => {
  it("prefers the link author over the note author", () => {
    expect(
      linkSenderEmail(
        link({
          author: { email: "link@updates.plot.day" },
          notes: [{ author: { email: "note@example.com" } }],
        })
      )
    ).toBe("link@updates.plot.day");
  });

  it("is null when no email-bearing author is present", () => {
    expect(linkSenderEmail(link({}))).toBeNull();
  });
});

describe("PLOT_SENDING_DOMAINS", () => {
  it("includes the dedicated transactional subdomain but never plot.day", () => {
    expect(PLOT_SENDING_DOMAINS).toContain("updates.plot.day");
    expect(PLOT_SENDING_DOMAINS).not.toContain("plot.day");
  });
});
