import { describe, it, expect } from "vitest";

import {
  selectCursorsToAdvance,
  type CursorEntityCount,
  type SyncCursorInfo,
} from "./twist-sync-cursor";

const HORIZON = "1000";

describe("selectCursorsToAdvance", () => {
  it("creates a cursor at the horizon for an entity with no existing row even when the poll returned 0 items", () => {
    // This is the L1 fix: previously a cursorless entity was skipped on a
    // 0-item poll, leaving its floor at the twist's install seq forever so
    // every alarm re-scanned the entity's entire global history. We now pin
    // the cursor at the horizon so the next poll only scans new churn.
    const entities: CursorEntityCount[] = [
      { entity: "schedule_contact", operation: "update", itemCount: 0 },
    ];
    const syncInfos: SyncCursorInfo[] = []; // no existing cursor row

    const result = selectCursorsToAdvance(entities, syncInfos, HORIZON);

    expect(result).toEqual([
      { entity: "schedule_contact", operation: "update", itemCount: 0 },
    ]);
  });

  it("advances when the poll returned items, regardless of any existing cursor", () => {
    const entities: CursorEntityCount[] = [
      { entity: "note", operation: "create", itemCount: 5 },
    ];

    expect(selectCursorsToAdvance(entities, [], HORIZON)).toEqual(entities);
  });

  it("advances an existing cursor that is behind the horizon on a 0-item poll", () => {
    const entities: CursorEntityCount[] = [
      { entity: "note_reaction", operation: "update", itemCount: 0 },
    ];
    const syncInfos: SyncCursorInfo[] = [
      { entity: "note_reaction", operation: "update", last_sync_seq_text: "500" },
    ];

    expect(selectCursorsToAdvance(entities, syncInfos, HORIZON)).toEqual(entities);
  });

  it("skips an existing cursor already at or past the horizon on a 0-item poll", () => {
    const entities: CursorEntityCount[] = [
      { entity: "thread", operation: "update", itemCount: 0 },
    ];
    const atHorizon: SyncCursorInfo[] = [
      { entity: "thread", operation: "update", last_sync_seq_text: "1000" },
    ];
    const pastHorizon: SyncCursorInfo[] = [
      { entity: "thread", operation: "update", last_sync_seq_text: "1500" },
    ];

    expect(selectCursorsToAdvance(entities, atHorizon, HORIZON)).toEqual([]);
    expect(selectCursorsToAdvance(entities, pastHorizon, HORIZON)).toEqual([]);
  });

  it("advances defensively when an existing cursor seq is unparseable", () => {
    const entities: CursorEntityCount[] = [
      { entity: "thread", operation: "update", itemCount: 0 },
    ];
    const syncInfos: SyncCursorInfo[] = [
      { entity: "thread", operation: "update", last_sync_seq_text: "not-a-number" },
    ];

    expect(selectCursorsToAdvance(entities, syncInfos, HORIZON)).toEqual(entities);
  });

  it("matches cursor rows on both entity and operation", () => {
    // A row for ("note","create") must not satisfy ("note","update").
    const entities: CursorEntityCount[] = [
      { entity: "note", operation: "update", itemCount: 0 },
    ];
    const syncInfos: SyncCursorInfo[] = [
      { entity: "note", operation: "create", last_sync_seq_text: "1500" },
    ];

    // No ("note","update") row exists -> create at horizon (L1).
    expect(selectCursorsToAdvance(entities, syncInfos, HORIZON)).toEqual(entities);
  });

  it("decides each entity independently in a mixed batch", () => {
    const entities: CursorEntityCount[] = [
      { entity: "schedule_contact", operation: "update", itemCount: 0 }, // no row -> create
      { entity: "thread", operation: "update", itemCount: 0 }, // caught up -> skip
      { entity: "note", operation: "create", itemCount: 3 }, // items -> advance
      { entity: "note_reaction", operation: "update", itemCount: 0 }, // behind -> advance
    ];
    const syncInfos: SyncCursorInfo[] = [
      { entity: "thread", operation: "update", last_sync_seq_text: "1000" },
      { entity: "note_reaction", operation: "update", last_sync_seq_text: "10" },
    ];

    const result = selectCursorsToAdvance(entities, syncInfos, HORIZON);

    expect(result.map((r) => r.entity)).toEqual([
      "schedule_contact",
      "note",
      "note_reaction",
    ]);
  });
});
