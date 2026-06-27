import { describe, expect, it, vi } from "vitest";
import { ActorType } from "@plotday/twister/plot";
import { Integrations } from "./integrations";

// Build an Integrations with a stubbed db that returns external-account rows.
// whereArgs collects every argument tuple passed to .where() for assertion.
function makeIntegrations(rows: Array<{ id: string; account_id: string }>, whereArgs: Array<any[]> = []) {
  const db = {
    selectFrom: vi.fn(() => db),
    innerJoin: vi.fn(() => db),
    select: vi.fn(() => db),
    where: vi.fn((...args: any[]) => { whereArgs.push(args); return db; }),
    execute: vi.fn(async () => rows),
    executeTakeFirst: vi.fn(async () => undefined),
  } as any;
  const i = Object.create(Integrations.prototype);
  i.db = db;
  i.twistInstanceId = "twist-1";
  return i as Integrations & { enrichTagActors: (note: any) => Promise<void> };
}

// Build an Integrations whose db.execute always throws.
function makeIntegrationsThrows() {
  const db = {
    selectFrom: vi.fn(() => db),
    innerJoin: vi.fn(() => db),
    select: vi.fn(() => db),
    where: vi.fn(() => db),
    execute: vi.fn(async () => { throw new Error("db error"); }),
    executeTakeFirst: vi.fn(async () => undefined),
  } as any;
  const i = Object.create(Integrations.prototype);
  i.db = db;
  i.twistInstanceId = "twist-1";
  return i as Integrations & { enrichTagActors: (note: any) => Promise<void> };
}

describe("tagActors enrichment", () => {
  it("maps each tag actor id to an Actor with source.accountId from contact_external_account", async () => {
    const whereArgs: any[][] = [];
    const i = makeIntegrations([
      { id: "actor-a", account_id: "trello-mem-A" },
      { id: "actor-b", account_id: "trello-mem-B" },
    ], whereArgs);
    const note: any = { tags: { "1": ["actor-a", "actor-b"], "3": ["actor-a"] }, author: { id: "actor-a", type: 1 }, tagActors: {} };
    await (i as any).enrichTagActors(note);
    expect(note.tagActors["actor-a"].source).toEqual({ accountId: "trello-mem-A" });
    expect(note.tagActors["actor-b"].source).toEqual({ accountId: "trello-mem-B" });
    expect(note.tagActors["actor-a"].type).toBe(ActorType.Contact);
    // author enriched too
    expect(note.author.source).toEqual({ accountId: "trello-mem-A" });
    // Security-critical: query must be scoped to this connector's twist instance id
    // to prevent cross-connector external-id leakage.
    expect(whereArgs.some((args) =>
      args[0] === "contact_external_account.twist_instance_id" &&
      args[1] === "=" &&
      args[2] === "twist-1"
    )).toBe(true);
  });

  it("sets source null for actors with no external account row", async () => {
    const i = makeIntegrations([]); // no rows
    const note: any = { tags: { "1": ["actor-x"] }, author: { id: "actor-x", type: 1 }, tagActors: {} };
    await (i as any).enrichTagActors(note);
    expect(note.tagActors["actor-x"].source).toBeNull();
  });

  it("degrades gracefully when the db query throws — resolves with tagActors: {}", async () => {
    const i = makeIntegrationsThrows();
    const note: any = { tags: { "1": ["actor-y"] }, author: { id: "actor-y", type: 1 }, tagActors: {} };
    await expect((i as any).enrichTagActors(note)).resolves.toBeUndefined();
    expect(note.tagActors).toEqual({});
  });
});
