import { describe, it, expect } from "vitest";

import { mapTaskStatus, buildLikeReactions, LIKE_EMOJI } from "./asana";
import { parseEventsError, AsanaSyncTokenError } from "./asana-api";

describe("mapTaskStatus", () => {
  it("returns 'done' when the task is completed, regardless of section", () => {
    expect(
      mapTaskStatus(
        {
          completed: true,
          memberships: [{ project: { gid: "P" }, section: { gid: "S1" } }],
        } as any,
        "P",
      ),
    ).toBe("done");
  });

  it("returns the section gid for an open task in a section of this project", () => {
    expect(
      mapTaskStatus(
        {
          completed: false,
          memberships: [{ project: { gid: "P" }, section: { gid: "S1" } }],
        } as any,
        "P",
      ),
    ).toBe("S1");
  });

  it("returns 'open' for an open task that is in no section", () => {
    expect(
      mapTaskStatus({ completed: false, memberships: [] } as any, "P"),
    ).toBe("open");
  });

  it("ignores section memberships belonging to a different project", () => {
    expect(
      mapTaskStatus(
        {
          completed: false,
          memberships: [{ project: { gid: "OTHER" }, section: { gid: "S9" } }],
        } as any,
        "P",
      ),
    ).toBe("open");
  });

  it("returns 'open' when memberships is missing entirely", () => {
    expect(mapTaskStatus({ completed: false } as any, "P")).toBe("open");
  });

  it("returns 'open' when a membership for this project has a null section", () => {
    expect(
      mapTaskStatus(
        {
          completed: false,
          memberships: [{ project: { gid: "P" }, section: null }],
        } as any,
        "P",
      ),
    ).toBe("open");
  });
});

describe("buildLikeReactions", () => {
  it("maps likes[] to per-user reactions under the like emoji", () => {
    const r = buildLikeReactions([
      { gid: "x", user: { gid: "u1", name: "Alice" } },
    ] as any);
    expect(Object.keys(r)).toEqual([LIKE_EMOJI]);
    expect(r[LIKE_EMOJI]).toHaveLength(1);
    const actor = r[LIKE_EMOJI]![0] as any;
    expect(actor.source?.accountId).toBe("u1");
    expect(actor.name).toBe("Alice");
  });

  it("maps multiple likers under the single like emoji", () => {
    const r = buildLikeReactions([
      { gid: "x", user: { gid: "u1", name: "Alice" } },
      { gid: "y", user: { gid: "u2", name: "Bob" } },
    ] as any);
    expect(r[LIKE_EMOJI]).toHaveLength(2);
    expect((r[LIKE_EMOJI]![1] as any).source?.accountId).toBe("u2");
  });

  it("returns an empty object for no likes", () => {
    expect(buildLikeReactions([])).toEqual({});
  });

  it("returns an empty object when likes is undefined", () => {
    expect(buildLikeReactions(undefined)).toEqual({});
  });

  it("skips likes without a user gid", () => {
    const r = buildLikeReactions([
      { gid: "x", user: { name: "No Gid" } },
      { gid: "y", user: { gid: "u2", name: "Bob" } },
    ] as any);
    expect(r[LIKE_EMOJI]).toHaveLength(1);
    expect((r[LIKE_EMOJI]![0] as any).source?.accountId).toBe("u2");
  });

  it("uses the 👍 thumbs-up as the like emoji", () => {
    expect(LIKE_EMOJI).toBe("👍");
  });
});

describe("parseEventsError", () => {
  it("extracts the fresh sync token from a 412 body", () => {
    expect(
      parseEventsError({ sync: "fresh-token-123", errors: [{ message: "x" }] }),
    ).toBe("fresh-token-123");
  });

  it("returns undefined when the body has no sync field", () => {
    expect(parseEventsError({ errors: [{ message: "x" }] })).toBeUndefined();
  });

  it("returns undefined when sync is not a string", () => {
    expect(parseEventsError({ sync: 42 })).toBeUndefined();
  });

  it("returns undefined for non-object bodies", () => {
    expect(parseEventsError(null)).toBeUndefined();
    expect(parseEventsError(undefined)).toBeUndefined();
    expect(parseEventsError("not json")).toBeUndefined();
  });
});

describe("AsanaSyncTokenError", () => {
  it("carries status 412 and the fresh sync token", () => {
    const err = new AsanaSyncTokenError("Asana API error 412: ...", "tok-9");
    expect(err.status).toBe(412);
    expect(err.sync).toBe("tok-9");
    expect(err).toBeInstanceOf(Error);
  });

  it("preserves an undefined sync token", () => {
    const err = new AsanaSyncTokenError("boom", undefined);
    expect(err.sync).toBeUndefined();
  });
});
