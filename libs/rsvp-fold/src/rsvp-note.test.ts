import { describe, expect, it } from "vitest";

import {
  alreadyFolded,
  composeRsvpNote,
  isNonAcceptance,
  shouldEmitRsvpNote,
  priorRsvpKey,
} from "./rsvp-note";
import type { RsvpReply } from "./rsvp-note";

function reply(overrides: Partial<RsvpReply> = {}): RsvpReply {
  return {
    partstat: "DECLINED",
    attendeeName: "Beth Round",
    attendeeEmail: "beth@example.test",
    occurrence: null,
    allDay: false,
    comment: null,
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

describe("alreadyFolded", () => {
  it("suppresses a repeat of the same response", () => {
    expect(alreadyFolded("DECLINED", reply({ partstat: "DECLINED" }))).toBe(true);
    expect(alreadyFolded("ACCEPTED", reply({ partstat: "ACCEPTED" }))).toBe(true);
  });
  it("does not suppress a changed response", () => {
    expect(alreadyFolded("DECLINED", reply({ partstat: "ACCEPTED" }))).toBe(false);
    expect(alreadyFolded("ACCEPTED", reply({ partstat: "DECLINED" }))).toBe(false);
  });
  it("does not suppress when nothing was ever folded", () => {
    expect(alreadyFolded(null, reply({ partstat: "DECLINED" }))).toBe(false);
    expect(alreadyFolded(undefined, reply({ partstat: "ACCEPTED" }))).toBe(false);
  });
});

describe("isNonAcceptance", () => {
  it("is true only for a decline or a tentative", () => {
    expect(isNonAcceptance("DECLINED")).toBe(true);
    expect(isNonAcceptance("TENTATIVE")).toBe(true);
    expect(isNonAcceptance("ACCEPTED")).toBe(false);
    expect(isNonAcceptance(null)).toBe(false);
    expect(isNonAcceptance(undefined)).toBe(false);
  });
});

describe("priorRsvpKey", () => {
  it("scopes the key to the event and the attendee", () => {
    expect(priorRsvpKey("uid-1@google.com", "beth@example.test", null)).toBe(
      "rsvp:uid-1@google.com:series:beth@example.test"
    );
  });

  it("normalises attendee case so a re-cased address hits the same key", () => {
    expect(priorRsvpKey("uid-1@google.com", "Beth@Example.Test", null)).toBe(
      priorRsvpKey("uid-1@google.com", "beth@example.test", null)
    );
  });

  it("uses the literal 'series' segment for a series-wide reply", () => {
    expect(priorRsvpKey("uid-1@google.com", "beth@example.test", null)).toBe(
      "rsvp:uid-1@google.com:series:beth@example.test"
    );
  });

  it("scopes the key to a single occurrence when the reply targets one", () => {
    const occurrence = new Date("2026-08-04T14:00:00Z");
    expect(priorRsvpKey("uid-1@google.com", "beth@example.test", occurrence)).toBe(
      `rsvp:uid-1@google.com:${occurrence.toISOString()}:beth@example.test`
    );
  });

  it("gives two different occurrences of the same uid+attendee different keys", () => {
    const aug4 = new Date("2026-08-04T14:00:00Z");
    const aug18 = new Date("2026-08-18T14:00:00Z");
    const keyAug4 = priorRsvpKey("uid-1@google.com", "beth@example.test", aug4);
    const keyAug18 = priorRsvpKey("uid-1@google.com", "beth@example.test", aug18);
    expect(keyAug4).not.toBe(keyAug18);
  });

  it("gives an occurrence-scoped reply a different key from the series-wide key", () => {
    const occurrence = new Date("2026-08-04T14:00:00Z");
    const seriesKey = priorRsvpKey("uid-1@google.com", "beth@example.test", null);
    const occurrenceKey = priorRsvpKey(
      "uid-1@google.com",
      "beth@example.test",
      occurrence
    );
    expect(seriesKey).not.toBe(occurrenceKey);
  });
});
