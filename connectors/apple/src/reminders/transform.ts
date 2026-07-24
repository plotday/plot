import { type ActorId, type NewLinkWithNotes } from "@plotday/twister";
import type { NewNote } from "@plotday/twister/plot";
import { Tag } from "@plotday/twister/tag";

import { parseICSDateTime } from "../ics-common";
import type { ICSTodo } from "./ics-todo-parser";

/** Globally-unique, cross-user dedup key: iCloud UIDs are unique per account/list. */
export function remindersSource(uid: string): string {
  return `icloud-reminders:reminder:${uid}`;
}

function todoDateString(due: ICSTodo["due"]): string | undefined {
  if (!due) return undefined;
  const parsed = parseICSDateTime(due);
  return typeof parsed === "string" ? parsed : parsed.toISOString().split("T")[0];
}

function createdDate(created: string | null): Date | undefined {
  if (!created) return undefined;
  const parsed = parseICSDateTime({ value: created, params: {} });
  return parsed instanceof Date ? parsed : undefined;
}

/**
 * Convert a parsed VTODO into a Plot `reminder` link. Returns `null` for a
 * CANCELLED todo — callers (sync.ts) archive any existing link for that
 * source instead of upserting one; CalDAV has no delete-vs-cancel
 * distinction from our side, but a cancelled reminder must not linger as an
 * open task.
 *
 * Recurring reminders (non-null `rrule`) are synced as their current master
 * state only — no per-occurrence expansion, per the design spec.
 *
 * `subtasks` are VTODOs whose RELATED-TO names this todo's UID (see the
 * design spec's flagged, unverified RELATED-TO assumption) — rendered as
 * Todo/Done-tagged notes on this thread, mirroring Google Tasks'
 * `transformTask`.
 */
export function transformTodo(
  todo: ICSTodo,
  resourceHref: string,
  listId: string,
  initialSync: boolean,
  subtasks: ICSTodo[],
  authActorId: ActorId | null
): NewLinkWithNotes | null {
  if (todo.status === "CANCELLED") return null;

  const isDone = todo.status === "COMPLETED";
  // Built as standalone variables (not inline array literals) so their `key`
  // field — valid on NewNote but excluded from the narrower `Omit<NewNote,
  // "thread">` the `notes` field's type collapses to — isn't rejected by
  // TS's excess-property check on a fresh object literal (same pattern as
  // ../mail/write.ts's composeLink).
  const notes: Omit<NewNote, "thread">[] = [];

  if (todo.description && todo.description.trim().length > 0) {
    const descriptionNote = {
      key: "description",
      content: todo.description,
      contentType: "text" as const,
      ...(authActorId ? { author: { id: authActorId } } : {}),
    };
    notes.push(descriptionNote);
  }

  for (const subtask of subtasks) {
    const subtaskDone = subtask.status === "COMPLETED";
    // `tags: { add: [...] }` mirrors google/tasks' transformTask and
    // todoist's subtask notes verbatim; NewTags's mapped-type shape
    // (`{ [K in Tag]?: NewActor[] }`) doesn't structurally include an "add"
    // key, so — matching those connectors' own `: any` escape hatch — this
    // is typed loosely rather than reshaped, to keep runtime behavior
    // identical to the established pattern.
    const subtaskNote: any = {
      key: `subtask-${subtask.uid}`,
      content: subtask.summary,
      tags: {
        add: subtaskDone ? [Tag.Done] : authActorId ? [{ id: authActorId }] : [Tag.Todo],
      },
      ...(subtaskDone ? {} : { twistTags: { [Tag.Todo]: true } }),
    };
    notes.push(subtaskNote);
  }

  return {
    source: remindersSource(todo.uid),
    type: "reminder",
    title: todo.summary,
    ...(createdDate(todo.created) ? { created: createdDate(todo.created) } : {}),
    channelId: listId,
    meta: {
      todoUid: todo.uid,
      todoHref: resourceHref,
      listId,
      syncProvider: "apple-reminders",
      channelId: listId,
    },
    author: authActorId ? { id: authActorId } : null,
    assignee: authActorId ? { id: authActorId } : null,
    status: isDone ? "done" : "open",
    notes,
    ...(isDone
      ? {}
      : {
          todo: true,
          ...(todoDateString(todo.due) ? { todoDate: todoDateString(todo.due) } : {}),
        }),
    ...(initialSync ? { unread: false, archived: false } : {}),
  };
}
