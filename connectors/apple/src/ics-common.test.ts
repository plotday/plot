import { describe, expect, it } from "vitest";

import {
  parseICSDateTime,
  parseParams,
  unescapeText,
  unfoldLines,
} from "./ics-common";

describe("unfoldLines", () => {
  it("joins a continuation line that starts with a space", () => {
    const folded = "SUMMARY:Buy milk\n and eggs\nEND:VTODO";
    expect(unfoldLines(folded)).toBe("SUMMARY:Buy milk and eggs\nEND:VTODO");
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
