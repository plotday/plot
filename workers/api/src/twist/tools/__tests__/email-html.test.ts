import { describe, expect, it, vi } from "vitest";

import {
  cleanConvertedMarkdown,
  convertNoteToMarkdown,
  preprocessEmailHtml,
} from "../plot/thread-helpers";

type Ai = Parameters<typeof convertNoteToMarkdown>[0];

// Fragment of an Iterable/Mailchimp-style email (Anthropic rate-limit update,
// Mon, 28 Jul 2025). This exact email rendered as a single run-on block of
// text because ai.toMarkdown collapsed <p> tags inside deeply nested layout
// tables into a single cell joined by spaces.
const ANTHROPIC_RATE_LIMIT_EMAIL = `
<table class="row row-2" role="presentation"><tbody><tr><td>
  <table class="row-content stack" role="presentation"><tbody><tr><td class="column column-1">
    <table class="text_block block-1" role="presentation"><tr><td class="pad">
      <div style="font-family:Georgia,serif">
        <div class="" style="font-size:14px;color:#000;line-height:1.2">
          <p style="margin:0;font-size:16px"><span>Hi there,</span></p>
          <p style="margin:0;font-size:16px">&nbsp;</p>
          <p style="margin:0;font-size:16px"><span>Next month, we're introducing new weekly rate limits for Claude subscribers, affecting less than 5% of users.</span></p>
          <p style="margin:0;font-size:16px">&nbsp;</p>
          <p style="margin:0;font-size:16px"><span><strong>What's changing:</strong></span></p>
          <p style="margin:0;font-size:16px"><span>Starting August 28, we're introducing weekly usage limits alongside our existing 5-hour limits:</span></p>
          <ul>
            <li><span><strong>Current</strong>: Usage limit that resets every 5 hours (no change)</span></li>
            <li><span><strong>New</strong>: Overall weekly limit that resets every 7 days</span></li>
            <li><span><strong>New</strong>: Claude Opus 4 weekly limit that resets every 7 days</span></li>
          </ul>
        </div>
      </div>
    </td></tr></table>
  </td></tr></tbody></table>
</td></tr></tbody></table>
`;

describe("preprocessEmailHtml", () => {
  it("strips all table structure while preserving paragraph/list content", async () => {
    const out = await preprocessEmailHtml(ANTHROPIC_RATE_LIMIT_EMAIL);

    // No table elements survive.
    expect(out).not.toMatch(/<table\b/i);
    expect(out).not.toMatch(/<tbody\b/i);
    expect(out).not.toMatch(/<thead\b/i);
    expect(out).not.toMatch(/<tr\b/i);
    expect(out).not.toMatch(/<td\b/i);
    expect(out).not.toMatch(/<th\b/i);

    // Paragraphs, list, and bold content survive.
    expect(out).toContain("<p");
    expect(out).toContain("<ul>");
    expect(out).toContain("<li>");
    expect(out).toContain("<strong>Current</strong>");
    expect(out).toContain("Hi there,");
    expect(out).toContain("What's changing:");
    expect(out).toContain("Overall weekly limit that resets every 7 days");
  });

  it("drops <style>/<script>/<head> blocks", async () => {
    const html = `
      <html>
        <head><title>t</title><style>.x{color:red}</style></head>
        <body>
          <script>alert(1)</script>
          <p>Body content</p>
        </body>
      </html>
    `;
    const out = await preprocessEmailHtml(html);
    expect(out).not.toMatch(/<style\b/i);
    expect(out).not.toMatch(/<script\b/i);
    expect(out).not.toMatch(/<head\b/i);
    expect(out).not.toContain("color:red");
    expect(out).not.toContain("alert(1)");
    expect(out).toContain("Body content");
  });

  it("preserves <h1>-<h6> tags so ai.toMarkdown emits Markdown headings", async () => {
    const html = `
      <html><body>
        <h1>Main title</h1>
        <h2>Section</h2>
        <h3>Subsection</h3>
        <h6>Caption</h6>
        <p>Body.</p>
      </body></html>
    `;
    const out = await preprocessEmailHtml(html);
    expect(out).toContain("<h1>Main title</h1>");
    expect(out).toContain("<h2>Section</h2>");
    expect(out).toContain("<h3>Subsection</h3>");
    expect(out).toContain("<h6>Caption</h6>");
  });

  it("strips HTML comments so adjacent text keeps its whitespace boundary", async () => {
    // React/JSX-rendered emails insert empty `<!-- -->` comments between
    // dynamic and static text segments (e.g. `Hi {name},`). ai.toMarkdown
    // treats a comment as a node boundary and collapses the surrounding
    // whitespace, gluing "Hi" to "Kris Braun". Removing the comment in
    // preprocessing leaves the real whitespace between the words intact.
    const html = `<p>
      Hi
      <!-- -->Kris Braun<!-- -->,
    </p>`;
    const out = await preprocessEmailHtml(html);
    expect(out).not.toContain("<!--");
    expect(out).not.toContain("-->");
    // The space (newline) between "Hi" and "Kris Braun" survives.
    expect(out).toMatch(/Hi\s+Kris Braun/);
  });

  it("strips Outlook conditional comments (which contain '>')", async () => {
    const html = `<p>Before</p><!--[if mso]><table><tr><td>Outlook only</td></tr></table><![endif]--><p>After</p>`;
    const out = await preprocessEmailHtml(html);
    expect(out).not.toContain("Outlook only");
    expect(out).not.toContain("[if mso]");
    expect(out).toContain("Before");
    expect(out).toContain("After");
  });

  it("rewrites td/tr/th to div", async () => {
    const html = `
      <table><tbody>
        <tr><th>Header</th></tr>
        <tr><td>Cell A</td><td>Cell B</td></tr>
      </tbody></table>
    `;
    const out = await preprocessEmailHtml(html);
    expect(out).not.toMatch(/<(table|tbody|tr|td|th)\b/i);
    expect(out).toContain("<div>Header</div>");
    expect(out).toContain("<div>Cell A</div>");
    expect(out).toContain("<div>Cell B</div>");
  });

  it("drops empty-recipient mailto: share buttons", async () => {
    const html = `<p>Story headline</p>
      <a href="mailto:?subject=Shared%20Via%20Firefox&body=Check%20this%20out">Share</a>`;
    const out = await preprocessEmailHtml(html);
    expect(out).not.toMatch(/mailto:\?/i);
    expect(out).not.toContain("Share");
    expect(out).toContain("Story headline");
  });

  it("preserves real mailto: links to a specific address", async () => {
    const html = `<p>Contact <a href="mailto:kris@example.com">Kris</a> directly.</p>`;
    const out = await preprocessEmailHtml(html);
    expect(out).toContain("mailto:kris@example.com");
    expect(out).toContain("Kris");
  });

  it("drops hidden preheader/teaser containers", async () => {
    const html = `
      <div style="display:none !important;visibility:hidden;opacity:0;max-height:0;">Plus: the hidden teaser</div>
      <span style="visibility:hidden">invisible span</span>
      <p style="opacity:0">transparent para</p>
      <p style="opacity:0.9">faint but visible</p>
      <p>Visible body.</p>`;
    const out = await preprocessEmailHtml(html);
    expect(out).not.toContain("hidden teaser");
    expect(out).not.toContain("invisible span");
    expect(out).not.toContain("transparent para");
    expect(out).toContain("faint but visible");
    expect(out).toContain("Visible body.");
  });

  it("drops 1x1 tracking-pixel images but keeps normal images", async () => {
    const html = `<p>Body</p>
      <img src="https://track.example/pixel.gif" width="1" height="1" alt="" />
      <img src="https://cdn.example/photo.jpg" width="600" height="400" alt="Photo" />`;
    const out = await preprocessEmailHtml(html);
    expect(out).not.toContain("track.example/pixel.gif");
    expect(out).toContain("cdn.example/photo.jpg");
    expect(out).toContain("Body");
  });
});

describe("cleanConvertedMarkdown — empty lines and paragraphs", () => {
  it("preserves non-empty Markdown headings", () => {
    const input = [
      "# Title",
      "",
      "## Section",
      "",
      "### Subsection",
      "",
      "Body paragraph.",
    ].join("\n");
    const out = cleanConvertedMarkdown(input);
    expect(out).toContain("# Title");
    expect(out).toContain("## Section");
    expect(out).toContain("### Subsection");
    expect(out).toContain("Body paragraph.");
  });

  it("drops empty headings from <h4></h4>-style placeholders", () => {
    const input = [
      "####",
      "",
      "Claude",
      "",
      "Search and update CRM records.",
      "",
      "####",
      "",
      "ChatGPT",
    ].join("\n");
    const out = cleanConvertedMarkdown(input);
    expect(out).not.toMatch(/^#+\s*$/m);
    expect(out).toContain("Claude");
    expect(out).toContain("ChatGPT");
  });

  it("strips invisible spacer characters (soft hyphen, CGJ, zero-width)", () => {
    // Mailchimp/customer.io-style preheader padding.
    const padding = "\u034F \u034F \u034F \u00AD \u00AD \u200B \u200B";
    const input = `Preview text.${padding}\n\nReal body content.`;
    const out = cleanConvertedMarkdown(input);
    expect(out).not.toMatch(/[\u034F\u00AD\u200B\uFEFF]/);
    expect(out).toBe("Preview text.\n\nReal body content.");
  });

  it("never emits consecutive blank lines", () => {
    const input = "Line A\n\n\n\n\nLine B\n\n\n\nLine C";
    const out = cleanConvertedMarkdown(input);
    expect(out).toBe("Line A\n\nLine B\n\nLine C");
  });

  it("drops lines of only whitespace, including hard-break trailing spaces", () => {
    // A line with just "  " (two trailing spaces) is a CommonMark hard line
    // break with nothing after. ai.toMarkdown emits these from <p>&nbsp;</p>
    // and similar layout-only constructs in email HTML. Treat them as blank.
    const input = "First.\n  \n  \nSecond.";
    const out = cleanConvertedMarkdown(input);
    expect(out).toBe("First.\n\nSecond.");
  });

  it("drops lines of only invisible/whitespace characters", () => {
    const input = "First.\n\n   \u034F \u00AD \u200B   \n\nSecond.";
    const out = cleanConvertedMarkdown(input);
    expect(out).toBe("First.\n\nSecond.");
  });

  it("drops empty list items and empty blockquotes", () => {
    const input = ["- item one", "-", "- item two", ">", "> real quote"].join(
      "\n"
    );
    const out = cleanConvertedMarkdown(input);
    expect(out).not.toMatch(/^-\s*$/m);
    expect(out).not.toMatch(/^>\s*$/m);
    expect(out).toContain("- item one");
    expect(out).toContain("- item two");
    expect(out).toContain("> real quote");
  });

  it("trims leading and trailing blank separators", () => {
    const input = "\n\n\u034F\n\nHello\n\n\u00AD\n\n";
    const out = cleanConvertedMarkdown(input);
    expect(out).toBe("Hello");
  });

  it("collapses CRLF/CR blank-line runs the same as LF runs", () => {
    // Outlook/Exchange HTML emits CRLF inside text content. When
    // `ai.toMarkdown` falls back to `stripHtmlToText`, the stripped text
    // ends up with mixed `\n` and `\r\n` separators. Each \r-only line
    // counts as visually empty (\r is trimmed by .trim()), so the run
    // should still collapse to a single blank separator.
    const input = "Best,\n\r\nShanzay\n\r\n \n\r\n\r\n\r\n\r\n\r\nShanzay Amjad";
    const out = cleanConvertedMarkdown(input);
    expect(out).toBe("Best,\n\nShanzay\n\nShanzay Amjad");
  });
});

describe("cleanConvertedMarkdown \u2014 multi-line links", () => {
  it("flattens links with a blank line after the opening bracket", () => {
    // ai.toMarkdown() pattern seen in LinkedIn newsletter emails:
    // each prominent link is emitted as `[\n\n  Link Text ](url)`, which is
    // not valid CommonMark and renders as raw text in any compliant renderer.
    const input = "[\n\nThe Beautiful Mess ](https://example.com/newsletter)";
    const out = cleanConvertedMarkdown(input);
    expect(out).toBe("[The Beautiful Mess](https://example.com/newsletter)");
  });

  it("flattens multiple broken links and collapses internal whitespace", () => {
    const input = [
      "[",
      "",
      "Single-Player vs. Multiplayer AI Series ](https://example.com/a)",
      "",
      "[",
      "",
      "John Cutler ](https://example.com/b)",
    ].join("\n");
    const out = cleanConvertedMarkdown(input);
    expect(out).toContain("[Single-Player vs. Multiplayer AI Series](https://example.com/a)");
    expect(out).toContain("[John Cutler](https://example.com/b)");
  });

  it("drops standalone image-links (decoration logos/icons)", () => {
    // Email headers/footers wrap a logo or social icon in a link, e.g.
    // `[ ![X Logo](icon.png) ](https://x.com/...)`. Each renders as a broken
    // image block with vertical margin, creating the "blank space" effect
    // the user sees in the note. Strip them — surrounding prose carries the
    // meaning and the destination URL is already linked elsewhere if needed.
    const input = "[ ![LinkedIn](https://cdn.example.com/icon.png) ](https://example.com/feed)";
    const out = cleanConvertedMarkdown(input);
    expect(out).toBe("");
  });

  it("drops a footer row of social-icon image-links", () => {
    const input = [
      "Sent by Letterboxd, P.O. Box 99280, Newmarket, Auckland 1149, New Zealand",
      "",
      "[ ![X Logo](https://cdn.example.com/x.png) ](https://x.com/letterboxd)",
      "[ ![Bluesky Logo](https://cdn.example.com/bsky.png) ](https://bsky.app/profile/letterboxd.social)",
      "[ ![YouTube Logo](https://cdn.example.com/yt.png) ](https://www.youtube.com/letterboxdhq)",
    ].join("\n");
    const out = cleanConvertedMarkdown(input);
    expect(out).toBe(
      "Sent by Letterboxd, P.O. Box 99280, Newmarket, Auckland 1149, New Zealand"
    );
  });

  it("preserves image-links that appear inline with other text", () => {
    // An image-link inside a paragraph (with words around it) stays — the line
    // carries real prose, so the image is part of richer content, not decoration.
    const input = "Read more: [ ![Logo](icon.png) ](https://example.com/post) — full text below.";
    const out = cleanConvertedMarkdown(input);
    expect(out).toContain("Read more:");
    expect(out).toContain("[ ![Logo](icon.png) ](https://example.com/post)");
    expect(out).toContain("full text below");
  });

  it("leaves well-formed single-line links untouched", () => {
    const input = "[Read the post](https://example.com/post)";
    const out = cleanConvertedMarkdown(input);
    expect(out).toBe(input);
  });

  it("drops links whose flattened label is empty", () => {
    const input = "[\n\n  \n\n](https://example.com/empty)";
    const out = cleanConvertedMarkdown(input);
    expect(out).not.toContain("example.com/empty");
  });
});

describe("cleanConvertedMarkdown — empty-alt images", () => {
  it("drops standalone images with empty alt text", () => {
    const input = "Hello\n\n![](https://www.gstatic.com/logo.png)\n\nWorld";
    const out = cleanConvertedMarkdown(input);
    expect(out).not.toContain("!");
    expect(out).toBe("Hello\n\nWorld");
  });

  it("drops image-links where the image has no alt", () => {
    // Common: `<a href="..."><img src="logo.png" /></a>` becomes
    // `[![](logo.png)](url)`. Without alt text there is nothing to display,
    // so the whole construct should be removed — not collapsed to `[!](url)`.
    const input = "Header\n\n[![](https://cdn.example.com/logo.png)](https://example.com)\n\nBody";
    const out = cleanConvertedMarkdown(input);
    expect(out).not.toMatch(/\[!\]/);
    expect(out).not.toContain("https://example.com");
    expect(out).toBe("Header\n\nBody");
  });

  it("preserves images that have alt text", () => {
    const input = "![Google](https://www.gstatic.com/logo.png)";
    const out = cleanConvertedMarkdown(input);
    expect(out).toBe(input);
  });

  it("drops standalone image-links even without spaces inside the link", () => {
    // Same standalone-decoration rule applies regardless of the whitespace
    // ai.toMarkdown chooses to emit inside the outer link brackets.
    const input = "[![LinkedIn](https://cdn.example.com/icon.png)](https://example.com/feed)";
    const out = cleanConvertedMarkdown(input);
    expect(out).toBe("");
  });
});

describe("cleanConvertedMarkdown — glued inline elements", () => {
  // ai.toMarkdown drops the whitespace between adjacent inline elements,
  // emitting `[a](u)and[b](u)` and `**bold**word`. The missing space is not
  // just ugly: a `**…**` run wedged between two word characters
  // (`Romanow**was`) is neither left- nor right-flanking per CommonMark, so it
  // can't close emphasis — the literal asterisks render as text. These repairs
  // restore the spacing so the Markdown both reads correctly and parses.

  it("restores spaces around a word wedged between two links", () => {
    const input =
      "Thanks to [gameon](https://gameon.example)and[Fasken](https://fasken.example) for sponsoring.";
    const out = cleanConvertedMarkdown(input);
    expect(out).toBe(
      "Thanks to [gameon](https://gameon.example) and [Fasken](https://fasken.example) for sponsoring."
    );
  });

  it("restores the space after bold text glued to the next word", () => {
    const input = "**Michele Romanow**was direct about the challenges.";
    const out = cleanConvertedMarkdown(input);
    expect(out).toBe("**Michele Romanow** was direct about the challenges.");
  });

  it("separates two directly adjacent links", () => {
    const input = "[gameon](https://a.example)[Fasken](https://b.example)";
    const out = cleanConvertedMarkdown(input);
    expect(out).toBe("[gameon](https://a.example) [Fasken](https://b.example)");
  });

  it("separates a word directly followed by a link", () => {
    const input = "see[the post](https://example.com/post) below";
    const out = cleanConvertedMarkdown(input);
    expect(out).toBe("see [the post](https://example.com/post) below");
  });

  it("does not insert a space when a link is followed by punctuation", () => {
    const input =
      "Read [the post](https://example.com/post), [docs](https://example.com/docs).";
    const out = cleanConvertedMarkdown(input);
    expect(out).toBe(input);
  });

  it("does not insert a space when bold is followed by punctuation", () => {
    const input = "She was **direct**. Then **blunt**, then kind.";
    const out = cleanConvertedMarkdown(input);
    expect(out).toBe(input);
  });

  it("leaves already-spaced links and bold untouched (idempotent)", () => {
    const links =
      "Thanks to [gameon](https://a.example) and [Fasken](https://b.example) for sponsoring.";
    const bold = "**Michele Romanow** was direct about the challenges.";
    expect(cleanConvertedMarkdown(links)).toBe(links);
    expect(cleanConvertedMarkdown(bold)).toBe(bold);
  });

  it("does not split an inline image from its surrounding text", () => {
    const input = "Read ![Logo](https://cdn.example.com/logo.png) now.";
    const out = cleanConvertedMarkdown(input);
    expect(out).toBe(input);
  });
});

describe("cleanConvertedMarkdown — duplicate same-href links", () => {
  it("keeps the first link and de-links a contiguous same-href repeat", () => {
    // Digest layout: headline and dek both link to the same story URL.
    const input = [
      "[What we learned from the exit](https://ex.com/story)",
      "",
      "[This generation may still turn out golden.](https://ex.com/story)",
    ].join("\n");
    const out = cleanConvertedMarkdown(input);
    expect(out).toBe(
      "[What we learned from the exit](https://ex.com/story)\n\nThis generation may still turn out golden."
    );
  });

  it("collapses a run of three same-href links to one", () => {
    const input = [
      "[Headline](https://ex.com/a)",
      "",
      "[Dek](https://ex.com/a)",
      "",
      "[Read more](https://ex.com/a)",
    ].join("\n");
    const out = cleanConvertedMarkdown(input);
    expect(out).toBe("[Headline](https://ex.com/a)\n\nDek\n\nRead more");
  });

  it("keeps links to different hrefs", () => {
    const input = "[Story A](https://ex.com/a)\n\n[Story B](https://ex.com/b)";
    const out = cleanConvertedMarkdown(input);
    expect(out).toBe(input);
  });

  it("keeps a same-href link that recurs after intervening prose", () => {
    const input = [
      "[Sign up](https://ex.com/join)",
      "",
      "We would love to have you at the event next week.",
      "",
      "[Sign up](https://ex.com/join)",
    ].join("\n");
    const out = cleanConvertedMarkdown(input);
    expect(out).toBe(input);
  });

  it("does not treat an inline image-link as a duplicate link", () => {
    // Inline image-links survive cleanup; the dedupe must ignore them so it
    // neither de-links them nor mis-reads their inner href.
    const input =
      "Read ![icon](https://cdn.example/i.png) then [Story](https://ex.com/a).";
    const out = cleanConvertedMarkdown(input);
    expect(out).toBe(input);
  });
});

describe("convertNoteToMarkdown HTML conversion", () => {
  const htmlNote = "<p>Hello world</p>";
  // Mirrors the real failure: Cloudflare's to-markdown service returns an HTML
  // error page (a transient 5xx) and the internal binding throws while trying
  // to JSON.parse the body — "Unexpected token '<', \"<!DOCTYPE \"...".
  const transientError = () =>
    new SyntaxError(`Unexpected token '<', "<!DOCTYPE "... is not valid JSON`);

  it("retries a transient toMarkdown failure before degrading", async () => {
    const toMarkdown = vi
      .fn()
      .mockRejectedValueOnce(transientError())
      .mockResolvedValueOnce({
        format: "markdown",
        data: "Hello CONVERTEDMARKER",
      });
    const ai = { toMarkdown } as unknown as Ai;

    const result = await convertNoteToMarkdown(ai, htmlNote, "html");

    expect(toMarkdown).toHaveBeenCalledTimes(2);
    // Proves the second (successful) conversion was used, not the
    // strip-to-text fallback (which would never emit CONVERTEDMARKER).
    expect(result).toContain("CONVERTEDMARKER");
  });

  it("degrades to stripped text and warns (not errors) when retries are exhausted", async () => {
    const toMarkdown = vi.fn().mockRejectedValue(transientError());
    const ai = { toMarkdown } as unknown as Ai;

    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

    const result = await convertNoteToMarkdown(ai, htmlNote, "html");

    // Graceful degradation: no throw, content preserved as plain text.
    expect(result).toContain("Hello world");
    // A handled, transient upstream failure must not be logged at error
    // severity (which pages on PostHog) — warn only.
    expect(errorSpy).not.toHaveBeenCalled();
    expect(warnSpy).toHaveBeenCalled();

    errorSpy.mockRestore();
    warnSpy.mockRestore();
  });
});
