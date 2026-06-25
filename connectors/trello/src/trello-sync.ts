import type { NewContact, NewLinkWithNotes } from "@plotday/twister";
import { type TrelloCard, type TrelloMember, cardCreatedAt } from "./trello-api";

function memberContact(m: TrelloMember): NewContact {
  return {
    name: m.fullName ?? m.username ?? "",
    avatar: m.avatarUrl ?? undefined,
    source: { accountId: m.id },
  };
}

export function transformCard(
  card: TrelloCard,
  boardId: string,
  initialSync: boolean,
): NewLinkWithNotes {
  const created = cardCreatedAt(card.id);
  const hasDesc = (card.desc ?? "").trim().length > 0;

  type CardNote = NonNullable<NewLinkWithNotes["notes"]>[number];
  const notes: CardNote[] = [];
  notes.push({ key: "description", content: hasDesc ? card.desc : null, created } as CardNote);

  for (const action of card.actions ?? []) {
    if (action.type !== "commentCard") continue;
    notes.push({
      key: `comment-${action.id}`,
      content: action.data.text,
      created: new Date(action.date),
      author: action.memberCreator ? memberContact(action.memberCreator) : undefined,
    } as CardNote);
  }

  for (const att of card.attachments ?? []) {
    notes.push({
      key: `attachment-${att.id}`,
      content: `[${att.name}](${att.url})`,
      created,
    } as CardNote);
  }

  const contacts = (card.members ?? []).map(memberContact);

  return {
    source: `trello:card:${card.id}`,
    type: "card",
    title: card.name,
    created,
    status: card.idList,
    channelId: boardId,
    sourceUrl: card.url,
    preview: hasDesc ? card.desc : card.name,
    meta: { syncProvider: "trello", boardId, cardId: card.id, idList: card.idList },
    ...(contacts.length > 0 ? { accessContacts: contacts } : {}),
    notes,
    // closed → always archived; open → archived:false on initial only
    ...(card.closed
      ? { archived: true }
      : initialSync
        ? { archived: false }
        : {}),
    ...(initialSync ? { unread: false } : {}),
  };
}
