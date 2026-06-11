import { describe, expect, it } from "vitest";
import { stripQuotedReply } from "./email-parsing";

describe("stripQuotedReply", () => {
  it("cuts Outlook appendonsend reply chains", () => {
    const html = `<div>New content</div><div id="appendonsend"></div><div>From: A<br>Sent: B<br>To: C<br>Subject: D</div>`;
    expect(stripQuotedReply(html, "html")).toBe("<div>New content</div>");
  });

  it("cuts gmail_quote blocks from cross-client replies", () => {
    const html = `<p>Reply</p><div class="gmail_quote">old</div>`;
    expect(stripQuotedReply(html, "html")).toBe("<p>Reply</p>");
  });

  it("preserves forwarded messages", () => {
    const text = "FYI\n---------- Forwarded message ---------\nFrom: x";
    expect(stripQuotedReply(text, "text")).toBe(text);
  });

  it("cuts plain-text 'On ... wrote:' quotes", () => {
    const text = "Thanks!\nOn Tue, Jun 10, 2026, Kris wrote:\n> earlier";
    expect(stripQuotedReply(text, "text")).toBe("Thanks!");
  });
});
