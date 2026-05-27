import { describe, expect, it } from "vitest";

// Import the strip helpers via relative path. The Gmail connector lives in
// the public submodule and only exports its `Gmail` class through its
// package entry point, so tests reach the lower-level helpers directly.
import {
  findOutlookHeaderTagAgnostic,
  stripQuotedReply,
} from "../../../../../../public/connectors/gmail/src/gmail-api";

describe("stripQuotedReply — Outlook variants", () => {
  it("strips a bold-wrapped Outlook reply header (existing behavior)", () => {
    const html = [
      "<p>Hi Kris, my response above.</p>",
      "<hr>",
      "<p>",
      "  <b>From:</b> Amjad, Shanzay<br>",
      "  <b>Sent:</b> May 22, 2026 10:22 AM<br>",
      "  <b>To:</b> Kris Braun <kris@plot.day><br>",
      "  <b>Subject:</b> Defendant's Claim",
      "</p>",
      "<p>Quoted body goes here, should be stripped.</p>",
    ].join("\n");
    const out = stripQuotedReply(html, "html");
    expect(out).toContain("Hi Kris, my response above.");
    expect(out).not.toContain("Quoted body goes here");
    expect(out).not.toContain("Amjad, Shanzay");
  });

  it("strips a corporate Outlook/Exchange header with no inline bold", () => {
    // Gowling-style: field labels rendered bold via a CSS class (or font tag)
    // rather than `<b>`/`<strong>`. The tight bold regex misses this; the
    // tag-agnostic fallback catches it.
    const html = [
      "<div>My response.</div>",
      "<div>&nbsp;</div>",
      "<div><span style=\"font-family:Calibri\">From:</span></div>",
      "<div>&nbsp;Amjad, Shanzay</div>",
      "<div><span style=\"font-family:Calibri\">Sent:</span> May 22, 2026 10:22 AM</div>",
      "<div><span style=\"font-family:Calibri\">To:</span> Kris Braun</div>",
      "<div><span style=\"font-family:Calibri\">Subject:</span> Defendant's Claim</div>",
      "<div>Quoted body, must be stripped.</div>",
    ].join("\n");
    const out = stripQuotedReply(html, "html");
    expect(out).toContain("My response.");
    expect(out).not.toContain("Quoted body, must be stripped.");
    expect(out).not.toContain("Amjad, Shanzay");
  });

  it("strips a header where labels sit inside <span style=\"font-weight:bold\">", () => {
    const html = [
      "<p>Reply prose.</p>",
      "<p><span style=\"font-weight:bold\">From:</span> Person A</p>",
      "<p><span style=\"font-weight:bold\">Sent:</span> Yesterday</p>",
      "<p><span style=\"font-weight:bold\">To:</span> Person B</p>",
      "<p><span style=\"font-weight:bold\">Subject:</span> Topic</p>",
      "<p>Older body.</p>",
    ].join("\n");
    const out = stripQuotedReply(html, "html");
    expect(out).toContain("Reply prose.");
    expect(out).not.toContain("Older body.");
  });

  it("does not false-match user prose that mentions From/Sent/To/Subject inline", () => {
    // The four labels appear in the user's prose but inline within sentences,
    // not at block boundaries. The tag-agnostic detector must not chop here.
    const html = [
      "<p>Yesterday I forwarded the message From: A, B (Sent: Friday) which I had to send",
      "To: my manager, Subject: a quick question.</p>",
    ].join(" ");
    const out = stripQuotedReply(html, "html");
    // Whole body preserved
    expect(out).toContain("Yesterday");
    expect(out).toContain("manager");
  });

  it("returns -1 from the tag-agnostic helper when no Outlook header is present", () => {
    const html = "<p>Just an ordinary email body.</p><p>No quoted reply.</p>";
    expect(findOutlookHeaderTagAgnostic(html)).toBe(-1);
  });

  it("finds the From: index via the tag-agnostic helper", () => {
    const html = [
      "<div>Hello world</div>",
      "<div>From:</div>",
      "<div>Alice</div>",
      "<div>Sent: today</div>",
      "<div>To: Bob</div>",
      "<div>Subject: hi</div>",
    ].join("\n");
    const idx = findOutlookHeaderTagAgnostic(html);
    expect(idx).toBeGreaterThan(0);
    // The reported index points to "From:" in the original HTML.
    expect(html.substring(idx, idx + 5)).toBe("From:");
  });
});
