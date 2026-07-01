import { describe, it, expect } from "vitest";
import { Integrations } from "./integrations";

// Unit tests for the `todo` boolean that Integrations.dispatch derives for a
// `thread_schedule` item and passes to a connector's onThreadToDo. `active` is
// the source of truth: a thread is a to-do when it has a scheduling intent
// (`on`/`at`) AND has not been completed. Two dispatch paths feed different row
// shapes in:
//   - Polling (twist_instance_thread_schedule view): carries `active`/`read_at`,
//     NO `archived_at`. Completion is `active === false`.
//   - Direct (POST /sync/schedules, schedule table row): carries `archived_at`,
//     NO `active`. Completion is `archived_at != null`.
// dispatch only touches this.sourceProvider, this.twistInstanceId and this.db,
// so we exercise it against a mock `this`.

const CONNECTOR = "connector-instance-id";

/**
 * Table-aware Kysely stub. `executeTakeFirst()` returns `link` for the link
 * lookup and `thread` for the thread lookup; anything else (e.g. the
 * user_contact actor lookup) returns undefined so the actor falls back to the
 * default — the todo derivation doesn't depend on it.
 */
function mockDbByTable(tables: { link?: unknown; thread?: unknown }) {
  function chain(table?: string): any {
    return {
      selectFrom: (t: string) => chain(t),
      innerJoin: () => chain(table),
      select: () => chain(table),
      where: () => chain(table),
      executeTakeFirst: async () =>
        table === "link"
          ? tables.link
          : table === "thread"
          ? tables.thread
          : undefined,
      execute: async () => [],
    };
  }
  return chain();
}

function makeThis() {
  return {
    sourceProvider: { provider: "gmail" },
    twistInstanceId: CONNECTOR,
    db: mockDbByTable({
      link: { meta: {}, channel_id: "INBOX", source: "gmail:thread:1" },
      thread: { id: "thread-1", title: "Test", archived_at: null },
    }),
  } as any;
}

const dispatchThreadSchedule = (item: any) =>
  (Integrations.prototype as any).dispatch.call(makeThis(), {
    itemType: "thread_schedule",
    item: { thread_id: "thread-1", ...item },
  });

/** Read the `todo` arg (index 2) from the onThreadToDo dispatch entry. */
async function todoFor(item: any): Promise<boolean> {
  const result = await dispatchThreadSchedule(item);
  expect(result).toHaveLength(1);
  expect(result[0].sourceMethod).toBe("onThreadToDo");
  return result[0].args[2] as boolean;
}

describe("Integrations.dispatch — thread_schedule → onThreadToDo todo derivation", () => {
  // Polling view rows (have active/read_at, no archived_at).
  it("active to-do (active=true, on set) → todo=true", async () => {
    expect(
      await todoFor({ on: "[1970-01-01,)", at: null, active: true, read_at: null })
    ).toBe(true);
  });

  it("completed to-do (active=false, on still set, read_at set) → todo=false", async () => {
    // Regression: marking a starred Gmail thread done leaves `on` populated but
    // flips active=false. The old derivation read a non-existent `archived_at`
    // and ignored `active`, so it computed todo=true and re-starred the thread.
    expect(
      await todoFor({
        on: "[1970-01-01,)",
        at: null,
        active: false,
        read_at: new Date(),
      })
    ).toBe(false);
  });

  it("read but still active (active=true, read_at set) → todo=true (reading does not clear a to-do)", async () => {
    expect(
      await todoFor({ on: "[1970-01-01,)", active: true, read_at: new Date() })
    ).toBe(true);
  });

  it("no scheduling intent (on/at null) → todo=false", async () => {
    expect(await todoFor({ on: null, at: null, active: true, read_at: null })).toBe(
      false
    );
  });

  // Direct schedule-table rows (have archived_at, no active).
  it("direct: active schedule row (archived_at null, on set, no active) → todo=true", async () => {
    expect(await todoFor({ on: "[2026-07-01,)", at: null, archived_at: null })).toBe(
      true
    );
  });

  it("direct: archived schedule row (archived_at set) → todo=false", async () => {
    expect(
      await todoFor({ on: "[2026-07-01,)", at: null, archived_at: new Date() })
    ).toBe(false);
  });
});
