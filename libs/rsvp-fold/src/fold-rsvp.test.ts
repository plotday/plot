import { describe, expect, it } from "vitest";

import { foldRsvp } from "./fold-rsvp";
import { priorRsvpKey, type RsvpReply } from "./rsvp-note";

const UID = "uid-1@example.test";

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

/**
 * A connector stand-in: an in-memory marker store, a note sink, and a log of
 * the effects in the order they happened (so "marker written after the note"
 * is observable, not just "both happened").
 */
function harness(stored: Record<string, string> = {}) {
  const markers = new Map<string, string>(Object.entries(stored));
  const notes: Record<string, unknown>[] = [];
  const effects: string[] = [];
  return {
    markers,
    notes,
    effects,
    ports: {
      readMarker: async (key: string) => {
        effects.push(`read:${key}`);
        return markers.get(key);
      },
      writeMarker: async (key: string, partstat: string) => {
        effects.push(`write:${key}=${partstat}`);
        markers.set(key, partstat);
      },
      saveNote: async (note: Record<string, unknown>) => {
        effects.push("saveNote");
        notes.push(note);
        // Deferred notes resolve to nothing when the event has not synced yet.
        return null;
      },
    },
  };
}

/** The note fields a connector supplies; overridable per test. */
function noteFields(overrides: Partial<{ key: string; created?: Date; unread: boolean }> = {}) {
  return { key: "message-1@example.test", unread: true, ...overrides };
}

describe("foldRsvp", () => {
  it("emits a note for a decline and records the response", async () => {
    const h = harness();

    const outcome = await foldRsvp({
      uid: UID,
      reply: reply(),
      note: noteFields({ created: new Date("2026-08-03T09:00:00Z") }),
      ...h.ports,
    });

    expect(outcome).toBe("emitted");
    expect(h.notes).toHaveLength(1);
    expect(h.notes[0]).toEqual({
      thread: { source: `icaluid:${UID}` },
      key: "message-1@example.test",
      content: "Beth Round declined.",
      contentType: "markdown",
      created: new Date("2026-08-03T09:00:00Z"),
      author: { email: "beth@example.test", name: "Beth Round" },
      unread: true,
      deferUntilThread: true,
    });
    expect(h.markers.get(priorRsvpKey(UID, "beth@example.test", null))).toBe("DECLINED");
  });

  it("writes no note and no marker for a bare acceptance", async () => {
    const h = harness();

    const outcome = await foldRsvp({
      uid: UID,
      reply: reply({ partstat: "ACCEPTED" }),
      note: noteFields(),
      ...h.ports,
    });

    // The whole reason the helper exists: a note is the only thing that could
    // mark the organiser's event thread unread, so a response that says
    // nothing new writes nothing at all.
    expect(outcome).toBe("suppressed");
    expect(h.notes).toHaveLength(0);
    expect(h.markers.size).toBe(0);
  });

  it("writes nothing at all when the same response was already folded", async () => {
    const key = priorRsvpKey(UID, "beth@example.test", null);
    const h = harness({ [key]: "DECLINED" });

    const outcome = await foldRsvp({
      uid: UID,
      reply: reply({ partstat: "DECLINED" }),
      note: noteFields(),
      ...h.ports,
    });

    expect(outcome).toBe("already-folded");
    expect(h.notes).toHaveLength(0);
    expect(h.effects).toEqual([`read:${key}`]);
  });

  it("emits an acceptance that reverses a prior decline, and updates the marker", async () => {
    const key = priorRsvpKey(UID, "beth@example.test", null);
    const h = harness({ [key]: "DECLINED" });

    const outcome = await foldRsvp({
      uid: UID,
      reply: reply({ partstat: "ACCEPTED" }),
      note: noteFields(),
      ...h.ports,
    });

    expect(outcome).toBe("emitted");
    expect(h.notes[0]!.content).toBe("Beth Round accepted.");
    // Now ACCEPTED, so a later repeat of this same acceptance is recognised as
    // already folded instead of emitted again.
    expect(h.markers.get(key)).toBe("ACCEPTED");
  });

  it("recognises a re-delivered bare acceptance as a repeat, not merely as uninteresting", async () => {
    const key = priorRsvpKey(UID, "beth@example.test", null);
    // The state left by the test above: an acceptance that DID earn a note.
    const h = harness({ [key]: "ACCEPTED" });

    const outcome = await foldRsvp({
      uid: UID,
      reply: reply({ partstat: "ACCEPTED" }),
      note: noteFields(),
      ...h.ports,
    });

    // A stored "ACCEPTED" exists precisely because that acceptance earned a
    // note (it reversed something), so this repeat has to be read as a repeat.
    // Nothing is written either way here — the case where the repeat check is
    // the only thing standing between a re-delivery and a re-raised unread is
    // the commented acceptance below.
    expect(outcome).toBe("already-folded");
    expect(h.notes).toHaveLength(0);
  });

  it("checks the repeat first, so a re-delivered commented acceptance is not re-emitted", async () => {
    const key = priorRsvpKey(UID, "beth@example.test", null);
    const h = harness({ [key]: "ACCEPTED" });

    // A comment makes `shouldEmitRsvpNote` say yes unconditionally, so ONLY
    // the repeat check standing ahead of it stops the second delivery of this
    // message from re-applying its unread intent to the event thread — the
    // one case where dropping that check writes a note it must not write.
    const outcome = await foldRsvp({
      uid: UID,
      reply: reply({ partstat: "ACCEPTED", comment: "Running 10 minutes late" }),
      note: noteFields(),
      ...h.ports,
    });

    expect(outcome).toBe("already-folded");
    expect(h.notes).toHaveLength(0);
  });

  it("writes the marker only after the note, and only on the emitting path", async () => {
    const key = priorRsvpKey(UID, "beth@example.test", null);
    const h = harness();

    await foldRsvp({ uid: UID, reply: reply(), note: noteFields(), ...h.ports });
    // A marker written before the note would survive a throwing save and
    // suppress the response permanently.
    expect(h.effects).toEqual([`read:${key}`, "saveNote", `write:${key}=DECLINED`]);

    // Suppressed and already-folded paths write no marker at all: it must keep
    // describing what the event thread actually carries.
    const suppressed = harness();
    await foldRsvp({
      uid: UID,
      reply: reply({ partstat: "ACCEPTED" }),
      note: noteFields(),
      ...suppressed.ports,
    });
    expect(suppressed.effects).toEqual([`read:${key}`]);

    const repeat = harness({ [key]: "DECLINED" });
    await foldRsvp({ uid: UID, reply: reply(), note: noteFields(), ...repeat.ports });
    expect(repeat.effects).toEqual([`read:${key}`]);
  });

  it("leaves `created` off the note entirely when the connector has no timestamp", async () => {
    const h = harness();

    await foldRsvp({ uid: UID, reply: reply(), note: noteFields(), ...h.ports });

    expect(h.notes[0]).not.toHaveProperty("created");
  });

  it("passes the connector's unread choice through unchanged", async () => {
    const h = harness();

    await foldRsvp({
      uid: UID,
      reply: reply(),
      note: noteFields({ unread: false }),
      ...h.ports,
    });

    // History ingested on first connect must not light up the event thread.
    expect(h.notes[0]!.unread).toBe(false);
  });

  it("scopes the marker to the occurrence a response answered", async () => {
    const occurrence = new Date("2026-08-04T14:00:00Z");
    const h = harness();

    await foldRsvp({
      uid: UID,
      reply: reply({ occurrence }),
      note: noteFields(),
      ...h.ports,
    });

    // A decline on one occurrence must not read as an outstanding
    // non-acceptance for a different occurrence of the same series.
    expect(h.markers.get(priorRsvpKey(UID, "beth@example.test", occurrence))).toBe(
      "DECLINED"
    );
    expect(h.markers.has(priorRsvpKey(UID, "beth@example.test", null))).toBe(false);
  });

  it("addresses the note by the event's uid, and names the responder by address when unnamed", async () => {
    const h = harness();

    await foldRsvp({
      uid: "other-uid@example.test",
      reply: reply({ attendeeName: null }),
      note: noteFields(),
      ...h.ports,
    });

    expect(h.notes[0]!.thread).toEqual({ source: "icaluid:other-uid@example.test" });
    expect(h.notes[0]!.content).toBe("beth@example.test declined.");
    expect(h.notes[0]!.author).toEqual({ email: "beth@example.test" });
  });
});
