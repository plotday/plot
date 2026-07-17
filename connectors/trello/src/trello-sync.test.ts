import { describe, expect, it } from "vitest";
import { Tag } from "@plotday/twister";
import { transformCard } from "./trello-sync";
import type { TrelloCard } from "./trello-api";

function card(overrides: Partial<TrelloCard> = {}): TrelloCard {
  return {
    id: "5f000000aaaaaaaaaaaaaaaa", // encodes 0x5f000000 epoch
    name: "Ship the thing",
    desc: "Steps to repro",
    idList: "list-todo",
    idBoard: "board-1",
    closed: false,
    url: "https://trello.com/c/abc/1-ship",
    idMembers: ["m1"],
    members: [{ id: "m1", fullName: "Ada", username: "ada", avatarUrl: "https://img/ada" }],
    attachments: [{ id: "att1", name: "spec.pdf", url: "https://t.co/spec", bytes: 10, mimeType: "application/pdf" }],
    actions: [
      {
        id: "create1",
        type: "createCard",
        date: "2026-01-01T00:00:00.000Z",
        memberCreator: { id: "m3", fullName: "Cara", username: "cara", avatarUrl: "https://img/cara" },
        data: { card: { id: "5f000000aaaaaaaaaaaaaaaa", name: "Ship the thing" } },
      },
      {
        id: "act1",
        type: "commentCard",
        date: "2026-01-03T00:00:00.000Z",
        memberCreator: { id: "m2", fullName: "Bob", username: "bob", avatarUrl: null },
        data: { text: "looks good" },
      },
    ],
    dateLastActivity: "2026-01-04T00:00:00.000Z",
    ...overrides,
  };
}

describe("transformCard", () => {
  it("maps a full card to a link with description, comment, attachment notes and member contacts", () => {
    const link = transformCard(card(), "board-1", false);
    expect(link.source).toBe("trello:card:5f000000aaaaaaaaaaaaaaaa");
    expect(link.type).toBe("card");
    expect(link.title).toBe("Ship the thing");
    expect(link.status).toBe("list-todo");
    expect(link.channelId).toBe("board-1");
    expect(link.sourceUrl).toBe("https://trello.com/c/abc/1-ship");
    expect(link.created).toEqual(new Date(0x5f000000 * 1000));
    expect(link.meta).toEqual({ syncProvider: "trello", boardId: "board-1", cardId: "5f000000aaaaaaaaaaaaaaaa", idList: "list-todo" });
    // members → accessContacts
    expect(link.accessContacts).toEqual([{ name: "Ada", avatar: "https://img/ada", source: { accountId: "m1" } }]);
    // link author comes from the createCard action's memberCreator (the card creator)
    expect(link.author).toEqual({ name: "Cara", avatar: "https://img/cara", source: { accountId: "m3" } });
    // notes: description + comment + attachment
    type KN = { key?: string; content?: string | null; created?: Date; author?: unknown };
    const kn = (link.notes ?? []) as KN[];
    expect(kn.map((n) => n.key)).toEqual(["description", "comment-act1", "attachment-att1"]);
    const desc = kn.find((n) => n.key === "description")!;
    expect(desc.author).toEqual({ name: "Cara", avatar: "https://img/cara", source: { accountId: "m3" } });
    const comment = kn.find((n) => n.key === "comment-act1")!;
    expect(comment.content).toBe("looks good");
    expect(comment.created).toEqual(new Date("2026-01-03T00:00:00.000Z"));
    expect(comment.author).toEqual({ name: "Bob", avatar: undefined, source: { accountId: "m2" } });
    const att = kn.find((n) => n.key === "attachment-att1")!;
    expect(att.content).toBe("[spec.pdf](https://t.co/spec)");
    expect(att.author).toEqual({ name: "Cara", avatar: "https://img/cara", source: { accountId: "m3" } });
  });

  it("leaves author undefined on the link and description note when there is no createCard action", () => {
    const link = transformCard(card({ actions: [] }), "board-1", false);
    expect(link.author).toBeUndefined();
    type KN = { key?: string; author?: unknown };
    const desc = (link.notes as KN[]).find((n) => n.key === "description")!;
    expect(desc.author).toBeUndefined();
  });

  it("sets unread:false + archived:false only on initial sync for open cards", () => {
    const initial = transformCard(card(), "b", true);
    expect(initial.unread).toBe(false);
    expect(initial.archived).toBe(false);
    const incremental = transformCard(card(), "b", false);
    expect(incremental).not.toHaveProperty("unread");
    expect(incremental).not.toHaveProperty("archived");
  });

  it("maps a closed card to archived:true on both initial and incremental", () => {
    expect(transformCard(card({ closed: true }), "b", true).archived).toBe(true);
    expect(transformCard(card({ closed: true }), "b", false).archived).toBe(true);
  });

  it("omits the description note content when desc is empty", () => {
    const link = transformCard(card({ desc: "" }), "b", false);
    type KN = { key?: string; content?: string | null };
    const desc = (link.notes as KN[])!.find((n) => n.key === "description")!;
    expect(desc.content).toBeNull();
  });
});

describe("transformCard checklists", () => {
  function withChecklists() {
    return card({
      members: [
        { id: "m1", fullName: "Ada", username: "ada", avatarUrl: null },
        { id: "m2", fullName: "Bob", username: "bob", avatarUrl: null },
      ],
      checklists: [
        {
          id: "cl1",
          name: "QA tasks",
          pos: 16384,
          checkItems: [
            { id: "ci1", name: "Write tests", state: "complete", pos: 100, idMember: "m1" },
            { id: "ci2", name: "Review PR", state: "incomplete", pos: 200, idMember: null },
            { id: "ci3", name: "Deploy", state: "complete", pos: 300, idMember: null },
          ],
        },
        { id: "cl2", name: "Empty", pos: 32768, checkItems: [] },
      ],
    });
  }

  it("emits one note per checkItem with section + item positions", () => {
    const link = transformCard(withChecklists(), "board-1", false, "owner1");
    type KN = { key?: string; content?: string | null; sectionKey?: string | null; sectionLabel?: string | null; sectionPosition?: string | null; itemPosition?: string | null; tags?: Record<number, unknown[]> };
    const notes = (link.notes ?? []) as KN[];
    const ci1 = notes.find((n) => n.key === "checkitem-ci1")!;
    expect(ci1.content).toBe("Write tests");
    expect(ci1.sectionKey).toBe("cl1");
    expect(ci1.sectionLabel).toBe("QA tasks");
    expect(ci1.sectionPosition).toBe("16384");
    expect(ci1.itemPosition).toBe("100");
  });

  it("skips empty checklists entirely", () => {
    const link = transformCard(withChecklists(), "board-1", false, "owner1");
    const keys = (link.notes ?? []).map((n) => (n as { key?: string }).key);
    expect(keys.filter((k) => k?.startsWith("checkitem-"))).toEqual(["checkitem-ci1", "checkitem-ci2", "checkitem-ci3"]);
  });

  it("assigns Tag.Todo from idMember and Tag.Done for a complete assigned item", () => {
    const link = transformCard(withChecklists(), "board-1", false, "owner1");
    const ci1 = (link.notes ?? []).find((n) => (n as { key?: string }).key === "checkitem-ci1")! as { tags?: Record<number, Array<{ source?: { accountId?: string } }>> };
    expect(ci1.tags?.[Tag.Todo]?.[0].source?.accountId).toBe("m1");
    expect(ci1.tags?.[Tag.Done]?.[0].source?.accountId).toBe("m1");
  });

  it("leaves an incomplete unassigned item untagged", () => {
    const link = transformCard(withChecklists(), "board-1", false, "owner1");
    const ci2 = (link.notes ?? []).find((n) => (n as { key?: string }).key === "checkitem-ci2")! as { tags?: Record<number, unknown[]> };
    expect(ci2.tags).toBeUndefined();
  });

  it("attributes Done to the owner for an unassigned complete item", () => {
    const link = transformCard(withChecklists(), "board-1", false, "owner1");
    const ci3 = (link.notes ?? []).find((n) => (n as { key?: string }).key === "checkitem-ci3")! as { tags?: Record<number, Array<{ source?: { accountId?: string } }>> };
    expect(ci3.tags?.[Tag.Todo]).toBeUndefined();
    expect(ci3.tags?.[Tag.Done]?.[0].source?.accountId).toBe("owner1");
  });

  it("omits owner Done when no ownerMemberId is provided", () => {
    const link = transformCard(withChecklists(), "board-1", false, undefined);
    const ci3 = (link.notes ?? []).find((n) => (n as { key?: string }).key === "checkitem-ci3")! as { tags?: Record<number, unknown[]> };
    expect(ci3.tags).toBeUndefined();
  });
});
