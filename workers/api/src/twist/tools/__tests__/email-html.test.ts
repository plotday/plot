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
