import { describe, expect, it } from "vitest";
import { recipientsFor } from "./gmail";

describe("recipientsFor", () => {
  const self = "me@example.com";
  const alice = "alice@example.com";
  const bob = "bob@example.com";

  it("includes all candidates when accessContactEmails is null (no constraint)", () => {
    expect(
      recipientsFor({
        accessContactEmails: null,
        candidates: [alice, bob],
        self,
      })
    ).toEqual([alice, bob]);
  });

  it("always excludes self regardless of constraint", () => {
    expect(
      recipientsFor({
        accessContactEmails: null,
        candidates: [self, alice, bob],
        self,
      })
    ).toEqual([alice, bob]);
  });

  it("filters to only accessContactEmails when constraint is set", () => {
    expect(
      recipientsFor({
        accessContactEmails: new Set([alice.toLowerCase()]),
        candidates: [alice, bob],
        self,
      })
    ).toEqual([alice]);
  });

  it("private note (empty accessContactEmails) → empty recipient list", () => {
    expect(
      recipientsFor({
        accessContactEmails: new Set(),
        candidates: [alice, bob],
        self,
      })
    ).toEqual([]);
  });

  it("excludes self even when self is in accessContactEmails", () => {
    expect(
      recipientsFor({
        accessContactEmails: new Set([self.toLowerCase(), alice.toLowerCase()]),
        candidates: [self, alice, bob],
        self,
      })
    ).toEqual([alice]);
  });

  it("preserves candidate order from input list", () => {
    expect(
      recipientsFor({
        accessContactEmails: new Set([
          bob.toLowerCase(),
          alice.toLowerCase(),
        ]),
        candidates: [alice, bob],
        self,
      })
    ).toEqual([alice, bob]);
  });

  it("is case-insensitive when matching self", () => {
    expect(
      recipientsFor({
        accessContactEmails: null,
        candidates: ["ME@EXAMPLE.COM", alice],
        self,
      })
    ).toEqual([alice]);
  });

  it("is case-insensitive when matching candidate emails against set entries", () => {
    // The set holds lowercase emails (caller normalises on insert);
    // candidates may be mixed-case and are lowercased before lookup.
    expect(
      recipientsFor({
        accessContactEmails: new Set(["alice@example.com"]),
        candidates: ["ALICE@EXAMPLE.COM", bob],
        self,
      })
    ).toEqual(["ALICE@EXAMPLE.COM"]);
  });

  it("returns empty list when all candidates are self", () => {
    expect(
      recipientsFor({
        accessContactEmails: null,
        candidates: [self, "ME@EXAMPLE.COM"],
        self,
      })
    ).toEqual([]);
  });

  it("handles empty candidates list gracefully", () => {
    expect(
      recipientsFor({
        accessContactEmails: null,
        candidates: [],
        self,
      })
    ).toEqual([]);
  });
});
