// Pure cursor-advance decision logic for TwistSync.alarm(), extracted so it can
// be unit-tested in isolation (mirrors the twist-sync-batching split).

/** A stored twist_instance_sync cursor row, with its seq rendered as text. */
export interface SyncCursorInfo {
  entity: string;
  operation: string;
  last_sync_seq_text: string;
}

/** One (entity, operation) poll outcome: how many items it returned. */
export interface CursorEntityCount {
  entity: string;
  operation: string;
  itemCount: number;
}

/**
 * Decide which (entity, operation) cursors to upsert to the horizon after a
 * poll. Returns the subset of `cursorEntities` that need an advance.
 *
 * The only case we skip is an existing cursor row already at or past the
 * horizon (a genuine no-op). Everything else advances:
 *  - itemCount > 0: move the cursor past the dispatched items.
 *  - existing row behind the horizon: catch it up.
 *  - NO existing row (even on a 0-item poll): CREATE the row at the horizon.
 *
 * That last case is the optimization. The write-path triggers only seed a
 * twist_instance_sync row for the twist a change is *routed* to, so a twist that
 * never receives a given entity (e.g. a Gmail connector and schedule_contact)
 * had no cursor row and fell back to its install-seq floor on every alarm —
 * re-scanning the entity's ENTIRE global seq history (a wide, ~0-row scan)
 * forever. Seeding the row at the horizon pins the floor so subsequent polls
 * only scan churn since the last poll.
 *
 * Safe because a 0-item poll proved there was nothing in [floor, horizon) for
 * this twist, so advancing to the horizon — the same upper bound the poll used
 * — cannot skip an undelivered item.
 */
export function selectCursorsToAdvance(
  cursorEntities: ReadonlyArray<CursorEntityCount>,
  syncInfos: ReadonlyArray<SyncCursorInfo>,
  horizonSeq: string
): CursorEntityCount[] {
  const horizonSeqBig = BigInt(horizonSeq);
  return cursorEntities.filter(({ entity, operation, itemCount }) => {
    if (itemCount > 0) return true;
    const info = syncInfos.find(
      (s) => s.entity === entity && s.operation === operation
    );
    if (!info) return true; // seed a fresh cursor at the horizon
    try {
      return BigInt(info.last_sync_seq_text) < horizonSeqBig;
    } catch {
      return true;
    }
  });
}
