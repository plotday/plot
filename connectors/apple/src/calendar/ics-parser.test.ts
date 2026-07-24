import { describe, expect, it } from "vitest";
import { attendeeIsSelf } from "./ics-parser";

describe("RSVP self-attendee matching", () => {
  it("matches a dot-variant of the account address", () => {
    const line = "ATTENDEE;PARTSTAT=ACCEPTED:mailto:krisbraun@gmail.com";
    expect(attendeeIsSelf(line, "kris.braun@gmail.com")).toBe(true);
  });

  it("does not match an address that merely starts with the account address", () => {
    const line = "ATTENDEE;PARTSTAT=ACCEPTED:mailto:kris@example.com.au";
    expect(attendeeIsSelf(line, "kris@example.com")).toBe(false);
  });
});
