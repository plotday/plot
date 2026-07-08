import type { ActorId } from "@plotday/twister/plot";
import type { NewNote } from "@plotday/twister/plot";
import { describe, expect, it } from "vitest";

import { Integrations } from "./integrations";

type AccountContact = { id: ActorId; email: string; name: string | null } | null;

/**
 * Build an Integrations tool without its constructor (Object.create) and stub
 * `getAccountContact`, so `applyAuthoredBySelf` can be exercised without a DB.
 * `getAccountContact` is the only `this` it touches.
 */
function toolWithAccount(account: AccountContact) {
  const t = Object.create(Integrations.prototype);
  let calls = 0;
  (t as { getAccountContact: () => Promise<AccountContact> }).getAccountContact =
    async () => {
      calls++;
      return account;
    };
  const applyAuthoredBySelf = (notes: NewNote[] | undefined): Promise<void> =>
    (t as { applyAuthoredBySelf: (n: NewNote[] | undefined) => Promise<void> })
      .applyAuthoredBySelf(notes);
  return { applyAuthoredBySelf, accountLookups: () => calls };
}

const owner: AccountContact = {
  id: "owner-actor" as ActorId,
  email: "owner@example.test",
  name: "Owner",
};

describe("Integrations.applyAuthoredBySelf", () => {
  it("credits an authoredBySelf note to the owner's contact by id, leaving others untouched", async () => {
    const { applyAuthoredBySelf } = toolWithAccount(owner);
    const notes: NewNote[] = [
      { thread: { source: "s" }, content: "my reply", authoredBySelf: true },
      {
        thread: { source: "s" },
        content: "their message",
        author: { name: "Them", source: { accountId: "them" } },
      },
    ];

    await applyAuthoredBySelf(notes);

    expect(notes[0].author).toEqual({ id: "owner-actor" });
    // A message from someone else keeps its own author.
    expect(notes[1].author).toEqual({ name: "Them", source: { accountId: "them" } });
  });

  it("overrides whatever stub author the connector set on the own message", async () => {
    const { applyAuthoredBySelf } = toolWithAccount(owner);
    const notes: NewNote[] = [
      {
        thread: { source: "s" },
        content: "my reply",
        authoredBySelf: true,
        author: { name: "You", source: { accountId: "" } },
      },
    ];

    await applyAuthoredBySelf(notes);

    expect(notes[0].author).toEqual({ id: "owner-actor" });
  });

  it("leaves the note author unchanged when the owner has no resolvable contact", async () => {
    const { applyAuthoredBySelf } = toolWithAccount(null);
    const stub = { name: "You", source: { accountId: "" } };
    const notes: NewNote[] = [
      { thread: { source: "s" }, content: "my reply", authoredBySelf: true, author: stub },
    ];

    await applyAuthoredBySelf(notes);

    expect(notes[0].author).toEqual(stub);
  });

  it("does not look up the account when no note is authoredBySelf", async () => {
    const { applyAuthoredBySelf, accountLookups } = toolWithAccount(owner);
    const notes: NewNote[] = [{ thread: { source: "s" }, content: "x" }];

    await applyAuthoredBySelf(notes);

    expect(accountLookups()).toBe(0);
    expect(notes[0].author).toBeUndefined();
  });
});
