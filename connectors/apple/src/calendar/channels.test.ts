import { describe, expect, it } from "vitest";

import { CALENDAR_LINK_TYPES } from "./channels";
import { MAIL_LINK_TYPES } from "../mail/channels";

/**
 * The link-type declaration is what gives a synced value its label, icon and
 * filter entry in the app. A status the sync emits but the config never
 * declares renders as a bare, unlabelled value — a silent gap, since nothing
 * fails at build or sync time. These tests pin the declaration to what the
 * sync actually produces.
 */
describe("CALENDAR_LINK_TYPES", () => {
  const event = CALENDAR_LINK_TYPES.find((t) => t.type === "event");

  it("declares every status the event sync can emit", () => {
    // `prepareEvent` (apple.ts) maps iCalendar STATUS onto exactly these:
    // CONFIRMED and anything unrecognised → "Confirmed", TENTATIVE →
    // "Tentative", and a cancellation → "Cancelled".
    const emitted = ["Confirmed", "Tentative", "Cancelled"];
    const declared = (event?.statuses ?? []).map((s) => s.status);
    for (const status of emitted) expect(declared).toContain(status);
  });

  it("hides the ubiquitous Confirmed status by default and labels the rest", () => {
    const byStatus = Object.fromEntries(
      (event?.statuses ?? []).map((s) => [s.status, s])
    );
    expect(byStatus["Confirmed"].hiddenDefault).toBe(true);
    expect(byStatus["Tentative"].hiddenDefault).toBeFalsy();
    expect(byStatus["Cancelled"].hiddenDefault).toBeFalsy();
    for (const s of event?.statuses ?? []) expect(s.label).toBeTruthy();
  });

  it("declares the attendee roles the sync derives from ATTENDEE;ROLE", () => {
    const roles = (event?.contactRoles ?? []).map((r) => r.id);
    expect(roles).toEqual(["required", "optional"]);
    // Exactly one default, as the role picker expects.
    expect((event?.contactRoles ?? []).filter((r) => r.default)).toHaveLength(1);
  });

  it("does not offer roster editing, which CalDAV write-back can't honour", () => {
    // Only the owner's own PARTSTAT is written back; attendees can't be added
    // or removed. Offering the UI would silently drop those edits.
    expect(event?.supportsContactChanges).toBeFalsy();
  });
});

describe("MAIL_LINK_TYPES", () => {
  const email = MAIL_LINK_TYPES.find((t) => t.type === "email");

  it("addresses per message, and accepts mid-thread recipient changes", () => {
    // These two travel together: the message model is what makes a per-note
    // recipient set meaningful, and the reply path resolves recipients from
    // the note's own access list. Setting either alone is a bug — the flag
    // without the model silently drops mid-thread additions, and the model
    // without the flag hides the affordance that produces them.
    expect(email?.sharingModel).toBe("message");
    expect(email?.supportsContactChanges).toBe(true);
  });

  it("has no statuses — an email thread is status-less", () => {
    expect(email?.statuses).toBeUndefined();
  });
});
