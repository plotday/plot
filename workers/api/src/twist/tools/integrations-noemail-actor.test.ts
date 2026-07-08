import { describe, it, expect } from "vitest";
import { Integrations } from "./integrations";
import { ActorType } from "@plotday/twister";

// buildActor's no-email branch (e.g. Slack user-token OAuth, or a hosted
// account whose owner-contact lookup missed) must resolve the connecting
// OWNER's existing primary contact — NOT mint a fresh blank contact linked to
// the owner. The old mint-a-blank behavior stranded a nameless, email-less
// "self" contact (via the sync_user_contact_from_contact trigger) that
// rendered as "Unknown" in the app once its contact_external_account row was
// cascade-deleted (connection removed/recreated). See resolveOwnerContact.

/**
 * Kysely stub that routes by the table passed to selectFrom/insertInto:
 *  - selectFrom("contact_external_account") → the CEA dedup lookup result
 *  - selectFrom("twist_instance")           → { owner_id } | undefined
 *  - selectFrom("contact")                  → resolveOwnerContact primary result
 *  - insertInto("contact")                  → flips calls.contactInserted (regression guard)
 */
function makeDb(opts: {
  ceaDedup?: { id: string; name: string | null };
  owner?: { owner_id: string };
  primaryContact?: { id: string; name: string | null };
}) {
  const calls = { contactInserted: false };
  const selectChain = (table: string) => {
    const c: any = {
      innerJoin: () => c,
      select: () => c,
      where: () => c,
      orderBy: () => c,
      executeTakeFirst: async () => {
        if (table === "contact_external_account") return opts.ceaDedup;
        if (table === "twist_instance") return opts.owner;
        if (table === "contact") return opts.primaryContact;
        return undefined;
      },
      execute: async () => [],
    };
    return c;
  };
  const db: any = {
    selectFrom: (table: string) => selectChain(table),
    insertInto: (table: string) => {
      if (table === "contact") calls.contactInserted = true;
      const ins: any = {
        values: () => ins,
        returning: () => ins,
        onConflict: () => ins,
        executeTakeFirst: async () => ({ id: "should-not-be-used" }),
        execute: async () => {},
      };
      return ins;
    },
  };
  return { db, calls };
}

function makeSelf(db: any) {
  return { twistInstanceId: "ti-1", db } as any;
}

const callBuildActor = (
  self: any,
  email: string | null,
  provider: string | undefined,
  providerUserId: string | null,
) =>
  (Integrations.prototype as any).buildActor.call(
    self,
    email,
    provider,
    providerUserId,
  );

describe("Integrations.buildActor — no-email OAuth", () => {
  it("binds to the owner's primary contact instead of minting a blank contact", async () => {
    const { db, calls } = makeDb({
      ceaDedup: undefined,
      owner: { owner_id: "owner-1" },
      primaryContact: { id: "primary-1", name: "Beth" },
    });

    const actor = await callBuildActor(makeSelf(db), null, "slack", "U123");

    expect(actor.id).toBe("primary-1");
    expect(actor.name).toBe("Beth");
    expect(actor.type).toBe(ActorType.Contact);
    // Regression: no fresh blank contact is created (no "Unknown" identity).
    expect(calls.contactInserted).toBe(false);
  });

  it("returns the already-bound contact when a contact_external_account row exists", async () => {
    const { db, calls } = makeDb({
      ceaDedup: { id: "bound-1", name: "Bound Account" },
      owner: { owner_id: "owner-1" },
      primaryContact: { id: "primary-1", name: "Beth" },
    });

    const actor = await callBuildActor(makeSelf(db), null, "slack", "U123");

    expect(actor.id).toBe("bound-1");
    expect(calls.contactInserted).toBe(false);
  });

  it("falls back to a synthetic actor (no contact insert) when there is no owner", async () => {
    const { db, calls } = makeDb({ ceaDedup: undefined, owner: undefined });

    const actor = await callBuildActor(makeSelf(db), null, "slack", "U123");

    expect(actor.type).toBe(ActorType.Contact);
    expect(actor.id).not.toBe("primary-1");
    expect(calls.contactInserted).toBe(false);
  });
});
