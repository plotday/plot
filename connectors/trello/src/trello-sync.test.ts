import { describe, expect, it } from "vitest";
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
    // notes: description + comment + attachment
    type KN = { key?: string; content?: string | null; created?: Date; author?: unknown };
    const kn = (link.notes ?? []) as KN[];
    expect(kn.map((n) => n.key)).toEqual(["description", "comment-act1", "attachment-att1"]);
    const comment = kn.find((n) => n.key === "comment-act1")!;
    expect(comment.content).toBe("looks good");
    expect(comment.created).toEqual(new Date("2026-01-03T00:00:00.000Z"));
    expect(comment.author).toEqual({ name: "Bob", avatar: undefined, source: { accountId: "m2" } });
    const att = kn.find((n) => n.key === "attachment-att1")!;
    expect(att.content).toBe("[spec.pdf](https://t.co/spec)");
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
