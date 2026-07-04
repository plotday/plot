import { describe, it, expect } from "vitest";
import { Integrations } from "./integrations";

// getIntegrationData now QUEUES its self-heal writes (mirror the DO channel
// list into public.channel, backfill twist_instance_connection) instead of
// awaiting them inline, so they stay off the read's response path. The route
// drains the queue after responding via flushDeferredSelfHeal, on a FRESH
// connection (the request db is torn down once the handler returns). These
// tests cover that drain in isolation using capturing stubs — the same style
// as integrations-channel-linktypes.test.ts.

/**
 * Capturing Kysely stub that records every `insertInto(table).values(...)`
 * and, optionally, throws when a given table is written (to exercise the
 * per-write self-guard).
 */
function captureDb(throwOnTable?: string) {
  const inserts: Array<{ table: string; values: any }> = [];
  const db = {
    insertInto: (table: string) => ({
      values: (v: any) => {
        inserts.push({ table, values: v });
        const execute = async () => {
          if (table === throwOnTable) throw new Error("FK violation");
        };
        return {
          onConflict: (_fn: any) => ({ execute }),
          execute,
        };
      },
    }),
  } as any;
  return { db, inserts };
}

function host(deferred: any[]) {
  return {
    twistInstanceId: "ti-1",
    sourceProvider: { provider: "linkedin", linkTypes: [] },
    providerConfigs: [],
    deferredSelfHeal: deferred,
    // Real methods under test.
    flattenChannels: (Integrations.prototype as any).flattenChannels,
    connectorLinkTypes: (Integrations.prototype as any).connectorLinkTypes,
    mirrorChannelsToDb: (Integrations.prototype as any).mirrorChannelsToDb,
    flushDeferredSelfHeal: (Integrations.prototype as any).flushDeferredSelfHeal,
    // flush must write via the PASSED db, never this.db — make any accidental
    // use of this.db fail loudly.
    db: {
      insertInto: () => {
        throw new Error("flush must use the passed db, not this.db");
      },
    },
  } as any;
}

describe("flushDeferredSelfHeal", () => {
  it("drains queued writes to the passed db and clears the queue", async () => {
    const h = host([
      { kind: "mirrorChannels", channels: [{ id: "li-1", title: "LinkedIn" }] },
      {
        kind: "ticBackfill",
        userId: "user-1",
        provider: "linkedin",
        actorId: "actor-1",
      },
    ]);
    const { db, inserts } = captureDb();

    await h.flushDeferredSelfHeal.call(h, db);

    // The channel mirror wrote via the passed db.
    const channelInsert = inserts.find((i) => i.table === "channel");
    expect(channelInsert).toBeTruthy();
    expect((channelInsert!.values as any[])[0].channel_id).toBe("li-1");

    // The twist_instance_connection backfill wrote the queued binding.
    const ticInsert = inserts.find(
      (i) => i.table === "twist_instance_connection"
    );
    expect(ticInsert).toBeTruthy();
    expect(ticInsert!.values).toMatchObject({
      twist_instance_id: "ti-1",
      user_id: "user-1",
      provider: "linkedin",
      actor_id: "actor-1",
    });
    expect(typeof ticInsert!.values.connected_at).toBe("string");

    // The queue is emptied so a later drain is a no-op.
    expect(h.deferredSelfHeal).toHaveLength(0);
  });

  it("swallows a failing write and still runs the rest", async () => {
    const h = host([
      { kind: "mirrorChannels", channels: [{ id: "li-1", title: "LinkedIn" }] },
      {
        kind: "ticBackfill",
        userId: "user-1",
        provider: "linkedin",
        actorId: "actor-1",
      },
    ]);
    // The channel write throws (e.g. FK violation from stale DO storage) — a
    // read-path repair must never surface, and the tic backfill must still run.
    const { db, inserts } = captureDb("channel");

    await expect(h.flushDeferredSelfHeal.call(h, db)).resolves.toBeUndefined();

    expect(
      inserts.some((i) => i.table === "twist_instance_connection")
    ).toBe(true);
    expect(h.deferredSelfHeal).toHaveLength(0);
  });

  it("is a no-op when nothing was queued", async () => {
    const h = host([]);
    const { db, inserts } = captureDb();
    await h.flushDeferredSelfHeal.call(h, db);
    expect(inserts).toHaveLength(0);
  });
});
