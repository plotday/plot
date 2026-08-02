import { describe, expect, it } from "vitest";

import type { CalendarReply } from "./gmail-api";
import { composeRsvpNote, shouldEmitRsvpNote, priorRsvpKey } from "./rsvp-note";

function reply(overrides: Partial<CalendarReply> = {}): CalendarReply {
  return {
    messageId: "m1",
    uid: "uid-1@google.com",
    partstat: "DECLINED",
    attendeeName: "Beth Round",
    attendeeEmail: "beth@example.test",
    occurrence: null,
    allDay: false,
    comment: null,
    sourceCreatedAt: new Date("2026-07-24T20:50:24Z"),
    ...overrides,
  };
}

describe("composeRsvpNote", () => {
  it("states a plain decline", () => {
    expect(composeRsvpNote(reply())).toBe("Beth Round declined.");
  });

  it("uses the right verb for each response", () => {
    expect(composeRsvpNote(reply({ partstat: "ACCEPTED" }))).toBe(
      "Beth Round accepted."
    );
    expect(composeRsvpNote(reply({ partstat: "TENTATIVE" }))).toBe(
      "Beth Round tentatively accepted."
    );
  });

  it("names the occurrence for a single instance of a series", () => {
    expect(
      composeRsvpNote(
        reply({ occurrence: new Date("2026-08-04T14:00:00Z") })
      )
    ).toBe("Beth Round declined the August 4, 2026 occurrence.");
  });

  it("names an all-day occurrence without shifting the date", () => {
    expect(
      composeRsvpNote(
        reply({ occurrence: new Date("2026-08-04T00:00:00Z"), allDay: true })
      )
    ).toBe("Beth Round declined the August 4, 2026 occurrence.");
  });

  it("quotes the personal note beneath the sentence", () => {
    expect(
      composeRsvpNote(reply({ comment: "Could we move this to Thursday?" }))
    ).toBe("Beth Round declined.\n\n> Could we move this to Thursday?");
  });

  it("quotes every line of a multi-line note", () => {
    expect(composeRsvpNote(reply({ comment: "Line one\nLine two" }))).toBe(
      "Beth Round declined.\n\n> Line one\n> Line two"
    );
  });

  it("combines occurrence and note", () => {
    expect(
      composeRsvpNote(
        reply({
          occurrence: new Date("2026-08-25T14:00:00Z"),
          comment: "Conflict, sorry",
        })
      )
    ).toBe(
      "Beth Round declined the August 25, 2026 occurrence.\n\n> Conflict, sorry"
    );
  });

  it("falls back to the address when no name is known", () => {
    expect(composeRsvpNote(reply({ attendeeName: null }))).toBe(
      "beth@example.test declined."
    );
  });
});

describe("shouldEmitRsvpNote", () => {
  it("emits for a decline or a tentative", () => {
    expect(shouldEmitRsvpNote(reply({ partstat: "DECLINED" }), false)).toBe(true);
    expect(shouldEmitRsvpNote(reply({ partstat: "TENTATIVE" }), false)).toBe(true);
  });

  it("suppresses a bare acceptance", () => {
    expect(shouldEmitRsvpNote(reply({ partstat: "ACCEPTED" }), false)).toBe(false);
  });

  it("emits an acceptance that carries a comment", () => {
    expect(
      shouldEmitRsvpNote(
        reply({ partstat: "ACCEPTED", comment: "Sounds good, I'll bring the deck" }),
        false
      )
    ).toBe(true);
  });

  it("emits an acceptance that follows a decline or tentative", () => {
    expect(shouldEmitRsvpNote(reply({ partstat: "ACCEPTED" }), true)).toBe(true);
  });

  it("treats an empty comment as no comment", () => {
    expect(shouldEmitRsvpNote(reply({ partstat: "ACCEPTED", comment: "" }), false)).toBe(
      false
    );
  });
});

describe("priorRsvpKey", () => {
  it("scopes the key to the event and the attendee", () => {
    expect(priorRsvpKey("uid-1@google.com", "beth@example.test")).toBe(
      "rsvp:uid-1@google.com:beth@example.test"
    );
  });

  it("normalises attendee case so a re-cased address hits the same key", () => {
    expect(priorRsvpKey("uid-1@google.com", "Beth@Example.Test")).toBe(
      priorRsvpKey("uid-1@google.com", "beth@example.test")
    );
  });
});
