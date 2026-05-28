import { describe, it, expect } from "vitest";
import { reconcileThreadContacts } from "./sharing";

describe("reconcileThreadContacts (50% removal heuristic)", () => {
  it("adds new recipients always", () => {
    expect(reconcileThreadContacts({ previous: ["a", "b"], incoming: ["a", "b", "c"] }))
      .toEqual(["a", "b", "c"]);
  });

  it("removes recipients when <=50% of previous were dropped", () => {
    // 1 of 3 dropped = 33% → real removal
    expect(reconcileThreadContacts({ previous: ["a", "b", "c"], incoming: ["a", "b"] }))
      .toEqual(["a", "b"]);
  });

  it("treats 50% removal as a real removal (2-person edge)", () => {
    // 1 of 2 dropped = 50% → real removal
    expect(reconcileThreadContacts({ previous: ["a", "b"], incoming: ["a"] }))
      .toEqual(["a"]);
  });

  it("ignores removal when >50% of previous were dropped (private subset reply)", () => {
    // 8 of 10 dropped = 80% → keep default
    expect(reconcileThreadContacts({
      previous: ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"],
      incoming: ["a", "b"],
    })).toEqual(["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"]);
  });

  it("still adds newcomers even when most others were dropped", () => {
    expect(reconcileThreadContacts({
      previous: ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"],
      incoming: ["a", "b", "z"],
    }).sort()).toEqual(["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "z"]);
  });

  it("is a no-op when previous and incoming are identical", () => {
    expect(reconcileThreadContacts({
      previous: ["a", "b", "c"],
      incoming: ["a", "b", "c"],
    }).sort()).toEqual(["a", "b", "c"]);
  });

  it("handles empty previous (first message)", () => {
    expect(reconcileThreadContacts({ previous: [], incoming: ["a", "b"] }).sort())
      .toEqual(["a", "b"]);
  });

  it("treats fully-empty incoming as a private reply (no removals)", () => {
    // 2 of 2 dropped = 100% → preserve previous as a private subset.
    expect(reconcileThreadContacts({ previous: ["a", "b"], incoming: [] }))
      .toEqual(["a", "b"]);
  });
});
