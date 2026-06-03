import { describe, expect, it } from "vitest";

import { mergeSeqRows } from "./links";

// mergeSeqRows is the pure merge/sort/slice helper extracted from the
// GET /sync/links two-view (user.link + user.link_redacted) handler. It must
// behave like the equivalent inline merge in threads.ts / notes.ts:
//   - seq cursor: sort by (seq asc, id asc), seq compared lexicographically as
//     a decimal string (it's an xid8 string); slice to limit.
//   - legacy updated_at cursor: sort by (updated_at asc, id asc); slice to limit.
// The redacted set carries revoked=true rows; they interleave with the visible
// set purely by the sort key.

describe("mergeSeqRows", () => {
  it("merges and sorts by seq then id when using the seq cursor", () => {
    const visible = [{ id: "b", seq: "9", revoked: false }];
    const redacted = [{ id: "a", seq: "7", revoked: true }];

    const merged = mergeSeqRows(visible, redacted, true, 200);

    expect(merged.map((r: any) => r.id)).toEqual(["a", "b"]);
    expect((merged[0] as any).revoked).toBe(true);
    expect((merged[1] as any).revoked).toBe(false);
  });

  it("breaks seq ties by id ascending", () => {
    const visible = [{ id: "z", seq: "5", revoked: false }];
    const redacted = [{ id: "a", seq: "5", revoked: true }];

    const merged = mergeSeqRows(visible, redacted, true, 200);

    expect(merged.map((r: any) => r.id)).toEqual(["a", "z"]);
  });

  it("slices the merged result to the requested limit", () => {
    const visible = [
      { id: "b", seq: "2", revoked: false },
      { id: "d", seq: "4", revoked: false },
    ];
    const redacted = [
      { id: "a", seq: "1", revoked: true },
      { id: "c", seq: "3", revoked: true },
    ];

    const merged = mergeSeqRows(visible, redacted, true, 2);

    // Sorted order is a(1), b(2), c(3), d(4); sliced to first 2.
    expect(merged.map((r: any) => r.id)).toEqual(["a", "b"]);
  });

  it("sorts by updated_at then id on the legacy cursor", () => {
    const older = new Date("2026-01-01T00:00:00.000Z");
    const newer = new Date("2026-02-01T00:00:00.000Z");
    const visible = [{ id: "b", updated_at: newer, revoked: false }];
    const redacted = [{ id: "a", updated_at: older, revoked: true }];

    const merged = mergeSeqRows(visible, redacted, false, 200);

    expect(merged.map((r: any) => r.id)).toEqual(["a", "b"]);
  });

  it("compares seq lexically as multi-digit decimal strings", () => {
    // xid8 strings can vary in length; "10" must sort after "9" because the
    // string comparison is on equal-length numeric strings in practice, but
    // the helper must at minimum keep distinct seqs ordered consistently.
    const visible = [{ id: "b", seq: "100", revoked: false }];
    const redacted = [{ id: "a", seq: "99", revoked: true }];

    const merged = mergeSeqRows(visible, redacted, true, 200);

    // "100" < "99" lexically, mirroring the existing threads.ts/notes.ts
    // string comparison; the helper must match that behavior exactly so the
    // page boundary stays identical to the single-view path.
    expect(merged.map((r: any) => r.id)).toEqual(["b", "a"]);
  });
});
