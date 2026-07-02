import {
  ActionType,
  type PlanOperation,
  type PlanOperationResult,
} from "@plotday/twister/plot";
import { createLogger } from "@plotday/worker-util";
import { FocusAccess, LinkAccess, ThreadAccess } from "@plotday/twister/tools/plot";
import { sql } from "kysely";

import { createDb } from "../../../db";
import type { Bindings } from "../../../env";
import { CallbackError } from "../../../errors";
import type { LoadResult } from "../../../state/callbacks";
import { disposeRpc } from "../../../utils/rpc";
import { Plot } from "./index";

/**
 * Executes a batch of plan operations sequentially.
 *
 * Called when a user approves a plan action. Each operation is mapped to the
 * corresponding Plot tool method. `createFocus` operations should be ordered
 * first by the planner so later operations can reference the new focus ids.
 */
export async function executePlan(
  plot: Plot,
  operations: PlanOperation[]
): Promise<PlanOperationResult[]> {
  const logger = createLogger({ twist_instance_id: plot.twistInstanceId });
  const results: PlanOperationResult[] = [];

  for (const op of operations) {
    try {
      switch (op.type) {
        case "createFocus": {
          await plot.createFocus({ id: op.focusId, title: op.title });
          results.push({ success: true });
          break;
        }
        case "updateThread": {
          const update: Record<string, unknown> = { id: op.threadId };
          if (op.changes.title !== undefined) update.title = op.changes.title;
          if (op.changes.archived !== undefined) update.archived = op.changes.archived;
          if (op.changes.type !== undefined) update.type = op.changes.type;
          if (op.changes.focus) update.focus = { id: op.changes.focus.id };
          await plot.updateThread(update as any);
          results.push({ success: true });
          break;
        }
        case "updateLink": {
          const linkUpdate: Record<string, unknown> = { id: op.linkId };
          if (op.changes.threadId !== undefined) linkUpdate.threadId = op.changes.threadId;
          await plot.updateLink(linkUpdate as any);
          results.push({ success: true });
          break;
        }
        case "createThread": {
          await plot.createThread({ title: op.title, focus: { id: op.focusId } });
          results.push({ success: true });
          break;
        }
        case "createNote": {
          await plot.createNote({ thread: { id: op.threadId }, content: op.content });
          results.push({ success: true });
          break;
        }
        case "updateFocus": {
          const focusUpdate: Record<string, unknown> = { id: op.focusId };
          if (op.changes.title !== undefined) focusUpdate.title = op.changes.title;
          if (op.changes.archived !== undefined) focusUpdate.archived = op.changes.archived;
          await plot.updateFocus(focusUpdate as any);
          results.push({ success: true });
          break;
        }
        default: {
          results.push({
            success: false,
            error: `Unknown operation type: ${(op as any).type}`,
          });
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

/** Defensive server-side ceiling on how many operations one plan may run. */
const MAX_PLAN_OPERATIONS = 50;

/**
 * Parse a `note.actions` value into an array of actions. Postgres `jsonb`
 * columns are already deserialized by the driver (so `raw` is normally an
 * array), but tolerate a JSON string for robustness across drivers/mocks.
 */
function parseStoredActions(raw: unknown): Array<Record<string, unknown>> {
  if (raw == null) return [];
  if (Array.isArray(raw)) return raw as Array<Record<string, unknown>>;
  if (typeof raw === "string") {
    try {
      const parsed = JSON.parse(raw);
      return Array.isArray(parsed) ? parsed : [];
    } catch {
      return [];
    }
  }
  return [];
}

/**
 * Resolves the SERVER-STORED plan action backing `fullToken`: the note the
 * twist persisted via `createNote({ actions: [planAction] })`, matched by its
 * `callback` token (parameterized JSONB containment — never string
 * interpolation) and scoped to `created_by = twistInstanceId` (the plan
 * note's creator IS the twist instance that owns the callback).
 *
 * Returns the stored plan action, or null when no stored plan backs the token.
 */
async function findStoredPlanAction(
  db: ReturnType<typeof createDb>,
  fullToken: string,
  twistInstanceId: string
): Promise<Record<string, unknown> | null> {
  const noteRow = await db
    .selectFrom("note")
    .select("actions")
    .where("created_by", "=", twistInstanceId)
    .where(
      sql<boolean>`actions @> ${JSON.stringify([
        { callback: fullToken },
      ])}::jsonb`
    )
    .executeTakeFirst();

  const storedAction = parseStoredActions(noteRow?.actions).find(
    (a) => a?.type === ActionType.plan && a?.callback === fullToken
  );
  return storedAction ?? null;
}

/**
 * Cheap existence check: does a server-stored plan note back this callback
 * token? Used by the REJECTED arm of the plan branch to verify plan-ness
 * before dispatching with the extra positional `approved` arg — a mislabeled
 * `type: "plan"` payload POSTed against a non-plan token must fall through
 * to the legacy single-arg dispatch instead of argument-shifting an
 * arbitrary callback's curried extraArgs. Any token-resolution failure
 * (invalid/expired/unknown token) returns false; the legacy dispatch then
 * surfaces the same error it always did.
 */
export async function storedPlanExists(
  env: Bindings,
  fullToken: string
): Promise<boolean> {
  const [doIdHex] = fullToken.split(":");
  const callbacksStub = env.CALLBACKS.get(env.CALLBACKS.idFromString(doIdHex));
  let twistInstanceId: string;
  try {
    // @ts-ignore TS2589: Type instantiation is excessively deep and possibly infinite.
    const load = (await callbacksStub.validateAndLoad(fullToken)) as LoadResult;
    if ("__error" in load) return false;
    twistInstanceId = load.callback.twistInstanceId;
  } finally {
    disposeRpc(callbacksStub);
  }

  const db = createDb(env);
  try {
    return (await findStoredPlanAction(db, fullToken, twistInstanceId)) !== null;
  } finally {
    await db.destroy();
  }
}

/**
 * Executes a user-approved plan for the twist that created it.
 *
 * TRUST MODEL: the operations executed here come from the SERVER-STORED plan
 * note (the twist persisted it via `createNote({ actions: [planAction] })`),
 * NOT from the approval request body. The approval POST supplies only the
 * decision (`approved`); any `operations` it carries are ignored for
 * execution. Execution is:
 *   - owner-only — the authenticated approver must equal the twist instance's
 *     `owner_id`;
 *   - authoritative — operations are read from the stored plan action matched
 *     by its `callback` token (parameterized JSONB containment, never string
 *     interpolation), scoped to `created_by = twistInstanceId`;
 *   - capped — at most {@link MAX_PLAN_OPERATIONS} operations run.
 *
 * Returns both the results AND the authoritative operations so the caller can
 * overwrite `action.operations` alongside `action.results` before dispatching
 * to the twist — `onPlanResponse` zips operations↔results by index, so they
 * must be the same array the results were produced from.
 *
 * The authenticated approval POST is the user's consent, so the Plot tool is
 * constructed with full admin access and WITHOUT `requireApproval` (the gate
 * exists to force plans; the plan was just approved).
 *
 * @param authenticatedUserId the user id from the approval request's app-auth
 *   session; a missing or mismatched id fails closed with `NOT_FOUND`.
 */
export async function executeApprovedPlan(
  env: Bindings,
  fullToken: string,
  authenticatedUserId: string | null | undefined
): Promise<{ results: PlanOperationResult[]; operations: PlanOperation[] }> {
  const [doIdHex] = fullToken.split(":");
  const callbacksStub = env.CALLBACKS.get(env.CALLBACKS.idFromString(doIdHex));
  let twistInstanceId: string;
  try {
    // @ts-ignore TS2589: Type instantiation is excessively deep and possibly infinite.
    const load = (await callbacksStub.validateAndLoad(fullToken)) as LoadResult;
    if ("__error" in load) {
      throw new CallbackError(load.type, load.context);
    }
    twistInstanceId = load.callback.twistInstanceId;
  } finally {
    disposeRpc(callbacksStub);
  }

  const db = createDb(env);
  try {
    // Owner-only: fetch the twist instance's owner and reject any approver who
    // is not that owner. Fails closed when the id is absent (no user context)
    // or does not match. NOT_FOUND is the closest existing type (403-ish; the
    // route surfaces it as an error without leaking plan existence).
    const instance = await db
      .selectFrom("twist_instance")
      .select("owner_id")
      .where("id", "=", twistInstanceId)
      .executeTakeFirst();
    if (!instance) {
      throw new CallbackError("NOT_FOUND", {
        operation: "executeApprovedPlan",
        twistInstanceId,
        reason: "Twist instance not found",
      });
    }
    if (!authenticatedUserId || authenticatedUserId !== instance.owner_id) {
      throw new CallbackError("NOT_FOUND", {
        operation: "executeApprovedPlan",
        twistInstanceId,
        reason: "Approver is not the plan owner",
      });
    }

    // Load the SERVER-STORED plan action by its callback token, scoped to the
    // twist instance that created the note (see findStoredPlanAction).
    const storedAction = await findStoredPlanAction(db, fullToken, twistInstanceId);
    if (!storedAction) {
      throw new CallbackError("NOT_FOUND", {
        operation: "executeApprovedPlan",
        twistInstanceId,
        reason: "No stored plan matches callback token",
      });
    }

    const storedOperations = Array.isArray(storedAction.operations)
      ? (storedAction.operations as PlanOperation[])
      : [];
    const operations = storedOperations.slice(0, MAX_PLAN_OPERATIONS);

    const plot = new Plot({
      db,
      twistInstanceId,
      env,
      options: {
        thread: { access: ThreadAccess.Full },
        focus: { access: FocusAccess.Full },
        link: { access: LinkAccess.Full },
      },
    });
    const results = await executePlan(plot, operations);
    return { results, operations };
  } finally {
    await db.destroy();
  }
}
