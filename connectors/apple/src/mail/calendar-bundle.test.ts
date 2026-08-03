import { describe, expect, it } from "vitest";

import { classifyICS, isCalendarAttachment } from "./calendar-bundle";

/** Build a minimal VCALENDAR/VEVENT ICS blob with the given top-level METHOD
 *  and VEVENT-scoped UID/SEQUENCE — mirrors the shape iCloud/Gmail send. */
function ics(opts: { method?: string; uid?: string; sequence?: number }): string {
  const lines = ["BEGIN:VCALENDAR", "VERSION:2.0"];
  if (opts.method) lines.push(`METHOD:${opts.method}`);
  lines.push("BEGIN:VEVENT");
  if (opts.uid !== undefined) lines.push(`UID:${opts.uid}`);
  if (opts.sequence !== undefined) lines.push(`SEQUENCE:${opts.sequence}`);
  lines.push("SUMMARY:Team sync");
  lines.push("DTSTART:20260801T140000Z");
  lines.push("END:VEVENT");
  lines.push("END:VCALENDAR");
  return lines.join("\r\n");
}

describe("isCalendarAttachment", () => {
  it("matches text/calendar", () => {
    expect(isCalendarAttachment("text/calendar")).toBe(true);
  });

  it("matches application/ics", () => {
    expect(isCalendarAttachment("application/ics")).toBe(true);
  });

  it("is case-insensitive", () => {
    expect(isCalendarAttachment("TEXT/CALENDAR")).toBe(true);
    expect(isCalendarAttachment("Application/ICS")).toBe(true);
  });

  it("does not match an unrelated mime type", () => {
    expect(isCalendarAttachment("application/pdf")).toBe(false);
    expect(isCalendarAttachment("image/png")).toBe(false);
  });
});

describe("classifyICS — the full classification matrix", () => {
  it("METHOD:CANCEL bundles (strongest signal), regardless of SEQUENCE", () => {
    const result = classifyICS(ics({ method: "CANCEL", uid: "evt-1", sequence: 3 }));
    expect(result).toEqual({ uid: "evt-1", kind: "cancel" });
  });

  it("METHOD:REQUEST with SEQUENCE > 0 (an update) bundles", () => {
    const result = classifyICS(ics({ method: "REQUEST", uid: "evt-2", sequence: 1 }));
    expect(result).toEqual({ uid: "evt-2", kind: "update" });
  });

  it("METHOD:REQUEST with SEQUENCE == 0 (bare initial invite) skips", () => {
    const result = classifyICS(ics({ method: "REQUEST", uid: "evt-3", sequence: 0 }));
    expect(result).toBeNull();
  });

  it("METHOD:REQUEST with no SEQUENCE at all defaults to 0 and skips", () => {
    const result = classifyICS(ics({ method: "REQUEST", uid: "evt-3b" }));
    expect(result).toBeNull();
  });

  it("METHOD:REPLY (an RSVP) skips", () => {
    const result = classifyICS(ics({ method: "REPLY", uid: "evt-4", sequence: 2 }));
    expect(result).toBeNull();
  });

  it("skips a METHOD:REPLY with no SEQUENCE too — folding is not this function's job", () => {
    // The null verdict says nothing about what becomes of the message: in a
    // sync pass a recognised response is folded onto the event's own thread
    // before it is ever offered here (see `sync.ts`).
    const raw = [
      "BEGIN:VCALENDAR",
      "METHOD:REPLY",
      "BEGIN:VEVENT",
      "UID:evt-reply@example.test",
      "END:VEVENT",
      "END:VCALENDAR",
    ].join("\r\n");

    expect(classifyICS(raw)).toBeNull();
  });

  it("returns null when the ICS has no UID at all", () => {
    const result = classifyICS(ics({ method: "CANCEL" }));
    expect(result).toBeNull();
  });

  it("returns null for an unrecognized/missing METHOD", () => {
    const result = classifyICS(ics({ uid: "evt-5", sequence: 1 }));
    expect(result).toBeNull();
  });

  it("reads METHOD from the VCALENDAR level, not scoped inside VEVENT", () => {
    // METHOD sits before BEGIN:VEVENT in every real invite; confirm the
    // regex-based reader still finds it there rather than requiring it
    // inside the VEVENT block.
    const raw = [
      "BEGIN:VCALENDAR",
      "METHOD:CANCEL",
      "BEGIN:VEVENT",
      "UID:evt-6",
      "END:VEVENT",
      "END:VCALENDAR",
    ].join("\r\n");
    expect(classifyICS(raw)).toEqual({ uid: "evt-6", kind: "cancel" });
  });

  it("is case-insensitive on METHOD value", () => {
    const result = classifyICS(ics({ method: "cancel", uid: "evt-7" }));
    expect(result).toEqual({ uid: "evt-7", kind: "cancel" });
  });

  it("unfolds RFC 5545 continuation lines before reading properties", () => {
    // A realistic fold: a long UID value wrapped onto a continuation line
    // (RFC 5545 §3.1 — a line starting with a space/tab continues the prior
    // line's value).
    const folded = [
      "BEGIN:VCALENDAR",
      "METHOD:CANCEL",
      "BEGIN:VEVENT",
      "UID:evt-8-part1",
      " -part2",
      "END:VEVENT",
      "END:VCALENDAR",
    ].join("\r\n");
    expect(classifyICS(folded)).toEqual({ uid: "evt-8-part1-part2", kind: "cancel" });
  });
});

describe("classifyICS — property reading after the shared-icsProp swap", () => {
  it("reads a folded UID line (RFC 5545 continuation) the same as before", () => {
    // A 75-octet line wrapped with CRLF + single space. The UID must come
    // back joined, not truncated at the fold.
    const ics = [
      "BEGIN:VCALENDAR",
      "METHOD:CANCEL",
      "BEGIN:VEVENT",
      "UID:this-is-a-deliberately-long-identifier-that-the-generator-wrapped",
      " -across-two-lines@example.test",
      "SEQUENCE:1",
      "END:VEVENT",
      "END:VCALENDAR",
    ].join("\r\n");

    expect(classifyICS(ics)).toEqual({
      uid: "this-is-a-deliberately-long-identifier-that-the-generator-wrapped-across-two-lines@example.test",
      kind: "cancel",
    });
  });

  it("ignores parameters on the property it reads", () => {
    const ics = [
      "BEGIN:VCALENDAR",
      "METHOD:REQUEST",
      "BEGIN:VEVENT",
      "UID;X-VENDOR-QUIRK=1:evt-params@example.test",
      "SEQUENCE:3",
      "END:VEVENT",
      "END:VCALENDAR",
    ].join("\r\n");

    expect(classifyICS(ics)).toEqual({ uid: "evt-params@example.test", kind: "update" });
  });
});
