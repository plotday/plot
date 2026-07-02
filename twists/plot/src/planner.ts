import { Type, type Static } from "typebox";

import type { Focus, PlanOperation, Thread, Uuid } from "@plotday/twister";

import type { ChatMessage } from "./messages";

/** AI-facing schema: createFocus carries only a title — ids are assigned during validation. */
export const OPERATIONS_SCHEMA = Type.Array(
  Type.Union([
    Type.Object({
      type: Type.Literal("updateThread"),
      threadId: Type.String(),
      threadTitle: Type.String(),
      changes: Type.Object({
        archived: Type.Optional(Type.Boolean()),
        title: Type.Optional(Type.String()),
        type: Type.Optional(Type.String()),
        focus: Type.Optional(Type.Object({ id: Type.String(), title: Type.String() })),
      }),
    }),
    Type.Object({
      type: Type.Literal("createThread"),
      title: Type.String(),
      focusId: Type.String(),
      focusTitle: Type.String(),
    }),
    Type.Object({
      type: Type.Literal("createNote"),
      threadId: Type.String(),
      threadTitle: Type.String(),
      content: Type.String(),
    }),
    Type.Object({
      type: Type.Literal("updateFocus"),
      focusId: Type.String(),
      focusTitle: Type.String(),
      changes: Type.Object({
        title: Type.Optional(Type.String()),
        archived: Type.Optional(Type.Boolean()),
      }),
    }),
    Type.Object({
      type: Type.Literal("createFocus"),
      title: Type.String(),
    }),
  ])
);

export type RawOperation = Static<typeof OPERATIONS_SCHEMA>[number];

export const PLANNER_SYSTEM_PROMPT =
  "You are an organizational assistant for a workspace. The user wants to reorganize their content.\n\n" +
  "Given the conversation, the user's request, and the available data, produce a JSON array of operations.\n\n" +
  "Available operation types:\n" +
  "- updateThread: Change a thread's title, archived status, or move it to a different focus. Use changes.focus with {id, title} to move. Set changes.archived to true to archive.\n" +
  "- createThread: Create a new thread in a specific focus.\n" +
  "- createNote: Add a note to an existing thread.\n" +
  "- updateFocus: Rename a focus or archive it.\n" +
  "- createFocus: Create a new focus. Use this when the user asks to move threads to a focus that doesn't exist yet; reference it from other operations by its exact title (leave their focus id empty). Focuses are flat — they have no parent.\n\n" +
  "Rules:\n" +
  "- Only reference thread IDs and focus IDs from the provided data (except titles of focuses you create with createFocus).\n" +
  "- Include the current title in threadTitle/focusTitle fields for display purposes.\n" +
  "- Be conservative: only include operations that clearly match the user's request.\n" +
  "- Tag changes are not supported. If the user asks about tags, return an empty array.\n" +
  "- Only active (non-archived) threads are included in the list below. Already-archived threads cannot be targeted.\n" +
  "- Return an empty array if the request doesn't match any actionable operations.";

export function buildPlannerPrompt(args: {
  request: string;
  conversation: ChatMessage[];
  threads: Thread[];
  focuses: Focus[];
}): string {
  const conversationContext = args.conversation
    .slice(-10)
    .map((m) => `${m.role === "assistant" ? "Assistant" : "User"}: ${m.content}`)
    .join("\n");
  const threadsContext = args.threads
    .map(
      (t) =>
        `${t.id} | ${t.title} | Focus: ${t.focus.title} (${t.focus.id}) | Archived: ${
          t.archived ? "yes" : "no"
        }`
    )
    .join("\n");
  const focusesContext = args.focuses.map((p) => `${p.id} | ${p.title}`).join("\n");
  return (
    `Recent conversation:\n${conversationContext}\n\n` +
    `Request: ${args.request}\n\n` +
    `Threads (${args.threads.length}):\n${threadsContext}\n\n` +
    `Focuses (${args.focuses.length}):\n${focusesContext}`
  );
}

const MAX_OPERATIONS = 50;

/**
 * Validates AI-proposed operations against known ids, assigns explicit ids
 * to new focuses (createFocus ordered first), and remaps title-references
 * to those ids. Pure — focus creation is deferred to server-side execution.
 */
export function validateOperations(
  raw: RawOperation[],
  threads: Array<{ id: string }>,
  focuses: Array<{ id: string }>,
  generateId: () => Uuid
): PlanOperation[] {
  const threadIds = new Set(threads.map((t) => t.id));
  const focusIds = new Set(focuses.map((f) => f.id));

  const newFocusByTitle = new Map<string, { focusId: Uuid; title: string }>();
  const createFocusOps: PlanOperation[] = [];
  for (const op of raw) {
    if (op.type !== "createFocus") continue;
    const key = op.title.toLowerCase();
    if (newFocusByTitle.has(key)) continue;
    const entry = { focusId: generateId(), title: op.title };
    newFocusByTitle.set(key, entry);
    createFocusOps.push({ type: "createFocus", focusId: entry.focusId, title: entry.title });
  }

  const rest: PlanOperation[] = [];
  for (const op of raw) {
    if (op.type === "createFocus") continue;

    if (op.type === "updateThread") {
      if (!threadIds.has(op.threadId)) continue;
      if (op.changes.focus) {
        const created = newFocusByTitle.get(op.changes.focus.title.toLowerCase());
        if (created) {
          op.changes.focus = { id: created.focusId, title: created.title };
        } else if (!focusIds.has(op.changes.focus.id)) {
          continue;
        }
      }
      rest.push(op as PlanOperation);
    } else if (op.type === "createThread") {
      const created = newFocusByTitle.get(op.focusTitle.toLowerCase());
      if (created) {
        op.focusId = created.focusId;
        op.focusTitle = created.title;
      } else if (!focusIds.has(op.focusId)) {
        continue;
      }
      rest.push(op as PlanOperation);
    } else if (op.type === "createNote") {
      if (!threadIds.has(op.threadId)) continue;
      rest.push(op as PlanOperation);
    } else if (op.type === "updateFocus") {
      if (!focusIds.has(op.focusId)) continue;
      rest.push(op as PlanOperation);
    }
  }

  // Drop createFocus ops nothing references (avoid approving empty focuses).
  const referenced = new Set<string>();
  for (const op of rest) {
    if (op.type === "updateThread" && op.changes.focus) referenced.add(op.changes.focus.id);
    if (op.type === "createThread") referenced.add(op.focusId);
  }
  const keptCreates = createFocusOps.filter((op) =>
    op.type === "createFocus" ? referenced.has(op.focusId) : true
  );

  return [...keptCreates, ...rest].slice(0, MAX_OPERATIONS);
}

export function describeOperation(op: PlanOperation): string {
  switch (op.type) {
    case "createFocus":
      return `Create focus **${op.title}**`;
    case "updateThread":
      if (op.changes.focus) return `Move **${op.threadTitle}** to **${op.changes.focus.title}**`;
      if (op.changes.archived) return `Archive **${op.threadTitle}**`;
      if (op.changes.title) return `Rename **${op.threadTitle}** to **${op.changes.title}**`;
      return `Update **${op.threadTitle}**`;
    case "createThread":
      return `Create thread **${op.title}** in **${op.focusTitle}**`;
    case "createNote":
      return `Add note to **${op.threadTitle}**`;
    case "updateFocus":
      if (op.changes.archived) return `Archive focus **${op.focusTitle}**`;
      if (op.changes.title) return `Rename focus **${op.focusTitle}** to **${op.changes.title}**`;
      return `Update focus **${op.focusTitle}**`;
    case "updateLink":
      return `Move **${op.linkTitle}**`;
    default:
      return "Unknown operation";
  }
}

export function summarizeOperations(ops: PlanOperation[]): string {
  return ops.map((op) => `- ${describeOperation(op)}`).join("\n");
}
