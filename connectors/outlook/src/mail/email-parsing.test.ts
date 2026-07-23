import { describe, expect, it } from "vitest";
import { stripQuotedReply } from "./email-parsing";

describe("stripQuotedReply", () => {
  it("cuts Outlook appendonsend reply chains", () => {
    const html = `<div>New content</div><div id="appendonsend"></div><div>From: A<br>Sent: B<br>To: C<br>Subject: D</div>`;
    expect(stripQuotedReply(html, "html")).toBe("<div>New content</div>");
  });

  it("cuts Outlook-for-Mac reply chains that label the date line 'Date:' with a Cc:", () => {
    const html =
      `<div>New content</div>` +
      `<div><b>From:</b> A<br><b>Date:</b> B<br><b>To:</b> C<br>` +
      `<b>Cc:</b> D<br><b>Subject:</b> E</div>`;
    expect(stripQuotedReply(html, "html")).toBe("<div>New content</div>");
  });

  it("cuts gmail_quote blocks from cross-client replies", () => {
    const html = `<p>Reply</p><div class="gmail_quote">old</div>`;
    expect(stripQuotedReply(html, "html")).toBe("<p>Reply</p>");
  });

  it("cuts Apple Mail <blockquote type=\"cite\"> quotes", () => {
    // The nested gmail_quote sits deeper in the byte stream than the first
    // cite blockquote, so the earliest boundary must win.
    const html =
      `<div>Reply body</div>` +
      `<blockquote type="cite">On Jul 2, 2026, Bob wrote:` +
      `<div class="gmail_quote">nested older quote</div></blockquote>`;
    expect(stripQuotedReply(html, "html")).toBe("<div>Reply body</div>");
  });

  it("cuts Yahoo Mail yahoo_quoted blocks", () => {
    const html =
      `<div>Reply body</div>` +
      `<div id="yahoo_quoted_123" class="yahoo_quoted">On Sat, Bob wrote: old</div>`;
    expect(stripQuotedReply(html, "html")).toBe("<div>Reply body</div>");
  });

  it("preserves forwarded messages", () => {
    const text = "FYI\n---------- Forwarded message ---------\nFrom: x";
    expect(stripQuotedReply(text, "text")).toBe(text);
  });

  it("cuts plain-text 'On ... wrote:' quotes", () => {
    const text = "Thanks!\nOn Tue, Jun 10, 2026, Bob wrote:\n> earlier";
    expect(stripQuotedReply(text, "text")).toBe("Thanks!");
  });

  it("cuts plain-text quotes whose 'On ... wrote:' attribution is itself quote-prefixed", () => {
    const text = "Thanks!\n> On Tue, Jun 10, 2026, at 9:00 AM, Bob <bob@example.com> wrote:\n> earlier";
    expect(stripQuotedReply(text, "text")).toBe("Thanks!");
  });
});
