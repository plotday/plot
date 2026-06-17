import { describe, expect, it, vi } from "vitest";

import { createDb, type DB } from "../../../db";
import type { Bindings } from "../../../env";
import { type Kysely } from "kysely";

import { resolveAutoThreadAnchor, type AutoThreadResolveParams } from "./auto-thread";

const DATABASE_URL = process.env.DATABASE_URL;

class Rollback extends Error {}

async function withDb<T>(fn: (trx: Kysely<DB>) => Promise<T>): Promise<T> {
  const db = createDb({ DATABASE_URL } as unknown as Bindings);
  let captured: T;
  try {
    await db.transaction().execute(async (trx: Kysely<DB>) => {
      captured = await fn(trx);
      throw new Rollback();
    });
  } catch (e) {
    if (!(e instanceof Rollback)) throw e;
  } finally {
    await db.destroy();
  }
  return captured!;
}

// Each test isolates itself on a unique (twist_id, conversation_key) so the
// chain logic is exercised without cross-test interference (the rollback also
// guarantees nothing persists).
let nextTwistId = Math.floor(Math.random() * 1_000_000_000) + 1;
function freshChain(): { twistId: number; conversationKey: string } {
  return { twistId: nextTwistId++, conversationKey: `chan-${Math.random().toString(36).slice(2)}` };
}

function params(
  base: { twistId: number; conversationKey: string },
  source: string,
  t: string,
  mode: "sequential" | "fold" = "sequential",
  excerpt: string | null = `excerpt-${source}`,
): AutoThreadResolveParams {
  return {
    twistId: base.twistId,
    conversationKey: base.conversationKey,
    messageSource: source,
    sourceCreatedAt: t,
    excerpt,
    mode,
  };
}

const T1 = "2026-06-17T10:00:00.000Z";
const T2 = "2026-06-17T10:01:00.000Z";
const T3 = "2026-06-17T10:02:00.000Z";

const ALWAYS = () => Promise.resolve(true);
const NEVER = () => Promise.resolve(false);

describe.skipIf(!DATABASE_URL)("resolveAutoThreadAnchor", () => {
  it("first message anchors to itself and never calls the continuation check", async () => {
    await withDb(async (db) => {
      const chain = freshChain();
      const decide = vi.fn(ALWAYS);
      const anchor = await resolveAutoThreadAnchor(db, params(chain, "msgA", T1), decide);
      expect(anchor).toBe("msgA");
      expect(decide).not.toHaveBeenCalled();
    });
  });

  it("folds a continuation into the previous message's anchor", async () => {
    await withDb(async (db) => {
      const chain = freshChain();
      await resolveAutoThreadAnchor(db, params(chain, "msgA", T1), NEVER); // A → self
      const anchor = await resolveAutoThreadAnchor(db, params(chain, "msgB", T2), ALWAYS);
      expect(anchor).toBe("msgA");
    });
  });

  it("starts a new thread when the continuation check declines", async () => {
    await withDb(async (db) => {
      const chain = freshChain();
      await resolveAutoThreadAnchor(db, params(chain, "msgA", T1), NEVER);
      const anchor = await resolveAutoThreadAnchor(db, params(chain, "msgB", T2), NEVER);
      expect(anchor).toBe("msgB");
    });
  });

  it("inherits the anchor transitively (C continues B which folded into A)", async () => {
    await withDb(async (db) => {
      const chain = freshChain();
      await resolveAutoThreadAnchor(db, params(chain, "msgA", T1), NEVER); // A → self
      await resolveAutoThreadAnchor(db, params(chain, "msgB", T2), ALWAYS); // B → A
      const anchor = await resolveAutoThreadAnchor(db, params(chain, "msgC", T3), ALWAYS); // C → B.anchor = A
      expect(anchor).toBe("msgA");
    });
  });

  it("fold mode always folds and never calls the continuation check", async () => {
    await withDb(async (db) => {
      const chain = freshChain();
      const decide = vi.fn(NEVER);
      await resolveAutoThreadAnchor(db, params(chain, "dmA", T1, "fold"), decide); // A → self
      const anchor = await resolveAutoThreadAnchor(db, params(chain, "dmB", T2, "fold"), decide);
      expect(anchor).toBe("dmA");
      expect(decide).not.toHaveBeenCalled();
    });
  });

  it("reuses the stored decision on re-resolve (decide-once) and skips the check", async () => {
    await withDb(async (db) => {
      const chain = freshChain();
      await resolveAutoThreadAnchor(db, params(chain, "msgA", T1), NEVER);
      const first = await resolveAutoThreadAnchor(db, params(chain, "msgB", T2), ALWAYS); // folds → A
      expect(first).toBe("msgA");
      const decide = vi.fn(NEVER); // would now decline, but the row is cached
      const second = await resolveAutoThreadAnchor(db, params(chain, "msgB", T2), decide);
      expect(second).toBe("msgA");
      expect(decide).not.toHaveBeenCalled();
    });
  });

  it("starts a new thread when the previous message is not yet assigned (out of order)", async () => {
    await withDb(async (db) => {
      const chain = freshChain();
      // Resolve the LATER message first — its earlier neighbour isn't assigned.
      const decide = vi.fn(ALWAYS);
      const anchor = await resolveAutoThreadAnchor(db, params(chain, "msgLate", T2), decide);
      expect(anchor).toBe("msgLate");
      expect(decide).not.toHaveBeenCalled();
    });
  });
});
