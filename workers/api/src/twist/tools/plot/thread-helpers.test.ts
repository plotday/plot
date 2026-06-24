import { describe, expect, it } from "vitest";

import {
  createPreviewFromMarkdown,
  markdownToPlainText,
  plainTextToMarkdown,
  selectThreadAuthorSpec,
  stripMarkdown,
} from "./thread-helpers";

describe("selectThreadAuthorSpec", () => {
  it("returns the explicit link author when present", () => {
    expect(
      selectThreadAuthorSpec({
        title: "t",
        author: { id: "contact-ada" },
        notes: [{ author: { id: "contact-other" } }],
      } as any)
    ).toEqual({ id: "contact-ada" });
  });

  it("falls back to the first note's author when the link has none", () => {
    // Gmail-style: no link author, each note carries its sender. Credit the
    // ORIGINATOR — the first note's author — never a later replier.
    expect(
      selectThreadAuthorSpec({
        title: "Workshop ideas",
        notes: [
          { author: { id: "contact-phil" } },
          { author: { id: "contact-stacy" } },
        ],
      } as any)
    ).toEqual({ id: "contact-phil" });
  });

  it("skips leading authorless notes to find the first author", () => {
    expect(
      selectThreadAuthorSpec({
        title: "t",
        notes: [{ content: "system note" }, { author: { id: "contact-bob" } }],
      } as any)
    ).toEqual({ id: "contact-bob" });
  });

  it("returns null when there is neither a link author nor a note author", () => {
    expect(selectThreadAuthorSpec({ title: "t" } as any)).toBeNull();
    expect(
      selectThreadAuthorSpec({ title: "t", notes: [{ content: "x" }] } as any)
    ).toBeNull();
  });
});

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

  it("collapses runs of blank lines between paragraphs to one paragraph break", () => {
    const input = "para 1\n\n\n\npara 2\n\npara 3";
    expect(plainTextToMarkdown(input)).toBe("para 1\n\npara 2\n\npara 3");
  });

  it("reflows a column-wrapped prose paragraph into one line", () => {
    // A text/plain email body hard-wrapped by the sending MTA at ~70 cols.
    // The single newlines are soft wraps, not paragraph breaks, so they must
    // reflow rather than become mid-sentence paragraph breaks.
    const input =
      "That sounds great to me! Unless Kris has other input, I'll look\n" +
      "forward to getting to see what you put together later in the week!";
    expect(plainTextToMarkdown(input)).toBe(
      "That sounds great to me! Unless Kris has other input, I'll look forward to getting to see what you put together later in the week!"
    );
  });

  it("reflows wrapped prose but keeps real paragraph breaks (blank lines)", () => {
    const input =
      "That sounds great to me! Unless Kris has other input, I'll look\n" +
      "forward to getting to see what you put together later in the week!\n" +
      "\n" +
      "Thanks for all your work on this Phil! I'm really excited for how it\n" +
      "will all come together!";
    expect(plainTextToMarkdown(input)).toBe(
      "That sounds great to me! Unless Kris has other input, I'll look forward to getting to see what you put together later in the week!\n\n" +
        "Thanks for all your work on this Phil! I'm really excited for how it will all come together!"
    );
  });

  it("does not reflow short deliberate line breaks", () => {
    // Short lines are deliberate breaks (signature, address) — keep them as
    // separate paragraphs rather than gluing them together.
    const input = "Thanks,\nBeth";
    expect(plainTextToMarkdown(input)).toBe("Thanks,\n\nBeth");
  });

  it("decodes common HTML entities", () => {
    expect(plainTextToMarkdown("a &amp; b")).toBe("a & b");
    expect(plainTextToMarkdown("&lt;tag&gt;")).toBe("<tag>");
  });

  it("keeps list items tight instead of separating them with paragraph breaks", () => {
    const input = "Intro:\n1. first\n2. second\n3. third";
    expect(plainTextToMarkdown(input)).toBe(
      "Intro:\n\n1. first\n2. second\n3. third"
    );
  });

  it("keeps bulleted lists tight", () => {
    const input = "- apples\n- oranges\n- pears";
    expect(plainTextToMarkdown(input)).toBe("- apples\n- oranges\n- pears");
  });

  it("unescapes markdown that upstream services escaped in plain text", () => {
    const input = "\\[Beth Round\\] said: 1\\. first 2\\. second";
    expect(plainTextToMarkdown(input)).toBe(
      "[Beth Round] said: 1. first 2. second"
    );
  });

  it("unescapes over-escaped list markers on their own line", () => {
    const input = "Summary:\n1\\. alpha\n2\\. beta";
    expect(plainTextToMarkdown(input)).toBe("Summary:\n\n1. alpha\n2. beta");
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

describe("markdownToPlainText", () => {
  it("renumbers numbered lists that use `1.` on every line", () => {
    const input = "Test a markdown note:\n\n1. It works\n1. Will it work?";
    expect(markdownToPlainText(input)).toBe(
      "Test a markdown note:\n\n1. It works\n2. Will it work?"
    );
  });

  it("preserves bullet markers and line breaks", () => {
    const input = "Groceries:\n\n- apples\n- oranges\n- pears";
    expect(markdownToPlainText(input)).toBe(
      "Groceries:\n\n- apples\n- oranges\n- pears"
    );
  });

  it("keeps link labels and drops markdown syntax around them", () => {
    const input = "See [the docs](https://example.com/docs) for details.";
    expect(markdownToPlainText(input)).toBe(
      "See the docs for details."
    );
  });

  it("renders mentions as @-prefixed names", () => {
    const input = "Hey [Beth Round](#@11111111-1111-1111-1111-111111111111) 👋";
    expect(markdownToPlainText(input)).toBe("Hey @Beth Round 👋");
  });

  it("strips emphasis markers but keeps their content", () => {
    const input = "**bold** and *italic* and ~~strike~~";
    expect(markdownToPlainText(input)).toBe("bold and italic and strike");
  });

  it("renumbers independently across separate list blocks", () => {
    const input = "1. one\n1. two\n\nbetween\n\n1. alpha\n1. beta";
    expect(markdownToPlainText(input)).toBe(
      "1. one\n2. two\n\nbetween\n\n1. alpha\n2. beta"
    );
  });

  it("leaves code block content untouched after removing fences", () => {
    const input = "Before\n\n```js\nconst x = 1;\n```\n\nAfter";
    expect(markdownToPlainText(input)).toBe(
      "Before\n\nconst x = 1;\n\nAfter"
    );
  });
});

describe("createPreviewFromMarkdown", () => {
  it("strips email preheader padding (zero-width invisibles)", () => {
    // Real-world newsletter preheader: a space + combining grapheme joiner
    // (U+034F) + zero-width space (U+200B) repeated to push later content out
    // of the inbox snippet. The invisibles are not matched by \s, so without
    // stripping them the collapse leaves the spaces between them intact and
    // the preview renders as text followed by a long run of blank space.
    const padding = " ͏​".repeat(20);
    const input = `Breathe some fresh air into your releases.${padding}Read the changelog`;
    const preview = createPreviewFromMarkdown(input);

    expect(preview).toBe(
      "Breathe some fresh air into your releases. Read the changelog"
    );
    expect(preview).not.toMatch(/͏|​/);
    // No consecutive spaces in the rendered preview.
    expect(preview).not.toMatch(/ {2,}/);
  });

  it("strips a variety of zero-width / invisible format characters", () => {
    const input =
      "Hello​‌‍⁠﻿­͏ world";
    expect(createPreviewFromMarkdown(input)).toBe("Hello world");
  });
});

describe("stripMarkdown", () => {
  it("removes zero-width / invisible format characters", () => {
    const input = "Read​ more͏ here";
    expect(stripMarkdown(input)).toBe("Read more here");
  });
});
