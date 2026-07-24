import { describe, expect, it } from "vitest";

import {
  parseICSDateTime,
  parseParams,
  unescapeText,
  unfoldLines,
} from "./ics-common";

describe("unfoldLines", () => {
  it("strips the inserted fold marker (CRLF+one whitespace), preserving a real space that already existed at the fold point", () => {
    // RFC 5545 folding INSERTS a synthetic CRLF+single-whitespace at an arbitrary
    // split point without touching surrounding content. Here the fold landed right
    // before the original real space in "milk and eggs" — so there are TWO spaces
    // after the \n: the inserted fold marker (stripped) and the original real one
    // (preserved).
    const folded = "SUMMARY:Buy milk\n  and eggs\nEND:VTODO";
    expect(unfoldLines(folded)).toBe("SUMMARY:Buy milk and eggs\nEND:VTODO");
  });

  it("strips exactly the inserted fold whitespace when there was no original space at the fold point", () => {
    const folded = "SUMMARY:Buy\n milk";
    expect(unfoldLines(folded)).toBe("SUMMARY:Buymilk");
  });

  it("normalizes CRLF to LF", () => {
    expect(unfoldLines("A:1\r\nB:2\r\n")).toBe("A:1\nB:2\n");
  });
});

describe("unescapeText", () => {
  it("unescapes commas, semicolons, backslashes, and \\n", () => {
    expect(unescapeText("a\\, b\\; c\\\\d\\ne")).toBe("a, b; c\\d\ne");
  });
});

describe("parseParams", () => {
  it("splits a property name with TZID and VALUE params", () => {
    expect(parseParams("DTSTART;TZID=America/New_York;VALUE=DATE")).toEqual({
      name: "DTSTART",
      params: { TZID: "America/New_York", VALUE: "DATE" },
    });
  });

  it("returns no params for a bare property name", () => {
    expect(parseParams("SUMMARY")).toEqual({ name: "SUMMARY", params: {} });
  });
});

describe("parseICSDateTime", () => {
  it("parses a VALUE=DATE all-day value into a YYYY-MM-DD string", () => {
    const result = parseICSDateTime({
      value: "20260901",
      params: { VALUE: "DATE" },
    });
    expect(result).toBe("2026-09-01");
  });

  it("parses a UTC datetime into a Date", () => {
    const result = parseICSDateTime({
      value: "20260901T130000Z",
      params: {},
    });
    expect(result).toBeInstanceOf(Date);
    expect((result as Date).toISOString()).toBe("2026-09-01T13:00:00.000Z");
  });
});
