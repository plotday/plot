import { type Action, ActionType, type Uuid } from "@plotday/twister";
import { type AISource } from "@plotday/twister/tools/ai";

/** Build navigation actions from referenced threads and web sources. */
export function buildActions(
  threadIds: Set<string>,
  currentThreadId: string,
  sources?: AISource[]
): Action[] {
  const actions: Action[] = [];

  for (const id of threadIds) {
    if (id === currentThreadId) continue;
    actions.push({ type: ActionType.thread, threadId: id as Uuid });
    if (actions.length >= 3) break;
  }

  if (sources) {
    let urls = 0;
    for (const source of sources) {
      if (source.sourceType === "url" && source.url) {
        actions.push({
          type: ActionType.external,
          title: source.title || source.url,
          url: source.url,
        });
        if (++urls >= 5) break;
      }
    }
  }

  return actions;
}
