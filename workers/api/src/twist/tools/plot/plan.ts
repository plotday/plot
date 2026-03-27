import type { PlanOperation } from "@plotday/twister/plot";
import { createLogger } from "@plotday/worker-util";

import type { Plot } from "./index";

/**
 * Executes a batch of plan operations sequentially.
 *
 * Called when a user approves a plan action. Each operation is mapped
 * to the corresponding Plot tool method.
 *
 * @param plot - The Plot tool instance (with admin permissions)
 * @param operations - Array of operations to execute
 * @returns Array of results (one per operation), with errors captured per-operation
 */
export async function executePlan(
  plot: Plot,
  operations: PlanOperation[]
): Promise<Array<{ success: boolean; error?: string }>> {
  const logger = createLogger({ priority_twist_id: plot.priorityTwistId });
  const results: Array<{ success: boolean; error?: string }> = [];

  for (const op of operations) {
    try {
      switch (op.type) {
        case "updateThread": {
          const update: Record<string, unknown> = {
            id: op.threadId,
          };
          if (op.changes.title !== undefined) update.title = op.changes.title;
          if (op.changes.archived !== undefined) update.archived = op.changes.archived;
          if (op.changes.type !== undefined) update.type = op.changes.type;
          if (op.changes.priority) update.priority = { id: op.changes.priority.id };
          await plot.updateThread(update as any);
          results.push({ success: true });
          break;
        }
        case "updateLink": {
          const linkUpdate: Record<string, unknown> = {
            id: op.linkId,
          };
          if (op.changes.threadId !== undefined) linkUpdate.threadId = op.changes.threadId;
          await plot.updateLink(linkUpdate as any);
          results.push({ success: true });
          break;
        }
        case "createThread": {
          await plot.createThread({
            title: op.title,
            priority: { id: op.priorityId },
          });
          results.push({ success: true });
          break;
        }
        case "createNote": {
          await plot.createNote({
            thread: { id: op.threadId },
            content: op.content,
          });
          results.push({ success: true });
          break;
        }
        case "updatePriority": {
          const priorityUpdate: Record<string, unknown> = {
            id: op.priorityId,
          };
          if (op.changes.title !== undefined) priorityUpdate.title = op.changes.title;
          if (op.changes.archived !== undefined) priorityUpdate.archived = op.changes.archived;
          if (op.changes.parent) priorityUpdate.parent = { id: op.changes.parent.id };
          await plot.updatePriority(priorityUpdate as any);
          results.push({ success: true });
          break;
        }
        default: {
          results.push({ success: false, error: `Unknown operation type: ${(op as any).type}` });
          break;
        }
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      logger.error(`Plan operation failed: ${op.type}`, error as Error);
      results.push({ success: false, error: message });
    }
  }

  return results;
}
