import type { LinkTypeConfig, StatusIcon } from "@plotday/twister/tools/integrations";
import type { TrelloList } from "./trello-api";

export const DONE_LIST_RE = /done|complete|closed|shipped|finished/i;

export function buildCardLinkType(lists: TrelloList[]): LinkTypeConfig {
  const sorted = [...lists].sort((a, b) => a.pos - b.pos);
  const statuses = sorted.map((list, i) => {
    const isDone = DONE_LIST_RE.test(list.name);
    const icon: StatusIcon = isDone ? "done" : i === 0 ? "todo" : "inProgress";
    return {
      status: list.id,
      label: list.name,
      icon,
      ...(isDone ? { done: true as const } : {}),
    };
  });
  const firstOpen = sorted.find((l) => !DONE_LIST_RE.test(l.name)) ?? sorted[0];
  return {
    type: "card",
    label: "Card",
    noteLabel: "Comment",
    sharingModel: "channel",
    composePlaceholder: "Create a Trello card",
    composeVerb: "Create",
    replyPlaceholder: "Add a comment",
    replyVerb: "Comment",
    logo: "https://api.iconify.design/logos/trello.svg",
    supportsAssignee: false,
    statuses,
    ...(firstOpen ? { compose: { status: firstOpen.id } } : {}),
  };
}
