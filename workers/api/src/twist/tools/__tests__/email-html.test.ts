import { describe, expect, it } from "vitest";

import { cleanConvertedMarkdown, preprocessEmailHtml } from "../plot/thread-helpers";

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
