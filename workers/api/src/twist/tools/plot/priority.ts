import type { Database } from "@plotday/db";
import {
  type NewFocus,
  type Focus,
  type FocusUpdate,
  type Uuid,
} from "@plotday/twister/plot";
import { FocusAccess } from "@plotday/twister/tools/plot";
import { sql } from "kysely";

import { generatePath } from "../../../utils/path";
import { fromDbPriority } from "./converters";
import type { Plot } from "./index";

// Focuses are flat. Internally they remain rows in the `priority` table (a
// non-root priority under the user's root, which is the Inbox), but the SDK
// surface exposes them with no parent/child relationships.

/**
 * Lists the twist owner's focuses (every non-root priority).
 * Requires FocusAccess.Full.
 */
export async function getFocuses(
  plot: Plot,
  options?: {
    includeArchived?: boolean;
  }
): Promise<Focus[]> {
  plot.requirePriorityAccess(FocusAccess.Full);

  const userId = await plot.getUserId();
  const rootId = await plot.getRootPriorityId();

  let query = plot.db
    .selectFrom("priority")
    .select(["id", "title", "archived_at", "key", "color", "icon"])
    .where("user_id", "=", userId)
    // Exclude the root (the Inbox) — it isn't a focus.
    .where("id", "!=", rootId);

  if (!options?.includeArchived) {
    query = query.where("archived_at", "is", null);
  }

  const rows = await query.orderBy("title", "asc").execute();
  return rows.map(fromDbPriority);
}

export async function createFocus(
  plot: Plot,
  focus: NewFocus
): Promise<Focus & { created: boolean }> {
  // Validate focus create access permissions
  plot.requirePriorityAccess(FocusAccess.Create);

  // If a key is provided, check if the focus already exists (idempotent upsert)
  if ("key" in focus && focus.key) {
    const existing = await getFocus(plot, { key: focus.key });
    if (existing) {
      return { ...existing, created: false };
    }
  }

  // Flat model: every focus is created under the twist owner's root (Inbox) so
  // it surfaces as a top-level focus. There is no nesting.
  const parentId = await plot.getRootPriorityId();
  await plot.validatePriorityAccess(parentId);

  const parentResult = await plot.db
    .selectFrom("priority")
    .select(["path", "created_by"])
    .where("id", "=", parentId)
    .executeTakeFirstOrThrow();

  // Generate child path in TypeScript (not via DB function — see utils/path.ts)
  const path = generatePath(parentResult.path as string);

  const dbPriority: Database["public"]["Tables"]["priority"]["Insert"] = {
    created_by: parentResult.created_by,
    // Per-user owner matches the parent's owner (the user the twist runs for).
    user_id: parentResult.created_by,
    title: focus.title,
    path: path as string,
    updated_by: plot.getUpdatedBy(),
    sync_depth: plot.syncDepth + 1,
  };

  if ("id" in focus && focus.id) {
    dbPriority.id = focus.id;
  }
  if ("key" in focus && focus.key) {
    dbPriority.key = focus.key;
  }
  if (focus.color !== undefined && focus.color !== null) {
    dbPriority.color = focus.color;
  }
  if (focus.icon !== undefined && focus.icon !== null) {
    dbPriority.icon = focus.icon;
  }

  const result = await plot.db
    .insertInto("priority")
    .values({
      ...dbPriority,
      // Twists don't know about roles, so default every twist-created focus to
      // the user's default role. This groups it under a role in the sidebar and
      // satisfies the priority_role_or_fyi CHECK (role_id IS NOT NULL OR is_fyi).
      role_id: sql<string>`public.default_role_id(${parentResult.created_by}::uuid)`,
    } as any)
    .returningAll()
    .executeTakeFirstOrThrow();

  return { ...fromDbPriority(result), created: true };
}

export async function getFocus(
  plot: Plot,
  focus: { id: Uuid } | { key: string }
): Promise<Focus | null> {
  plot.requirePriorityAccess(FocusAccess.Create);

  let dbPriority;

  if ("key" in focus) {
    // Look up by key, scoped to the twist's priority root.
    const priorityRoot = await plot.getPriorityRoot();
    const result = await plot.db
      .selectFrom("priority")
      .select(["id", "title", "archived_at", "key", "color", "icon"])
      .where("key", "=", focus.key)
      .where(sql<boolean>`path <@ ${priorityRoot}::ltree`)
      .executeTakeFirst();

    if (!result) {
      return null;
    }
    dbPriority = result;
  } else {
    const result = await plot.db
      .selectFrom("priority")
      .select(["id", "title", "archived_at", "key", "color", "icon"])
      .where("id", "=", focus.id)
      .executeTakeFirst();

    if (!result) {
      return null;
    }
    dbPriority = result;
  }

  try {
    await plot.validatePriorityAccess(dbPriority.id);
  } catch {
    return null;
  }

  return fromDbPriority(dbPriority);
}

export async function updateFocus(
  plot: Plot,
  update: FocusUpdate
): Promise<void> {
  plot.requirePriorityAccess(FocusAccess.Create);

  // Resolve the focus id (key lookup scoped to the twist's priority root).
  let priorityId: string;

  if ("key" in update) {
    const priorityRoot = await plot.getPriorityRoot();
    const result = await plot.db
      .selectFrom("priority")
      .select("id")
      .where("key", "=", update.key)
      .where(sql<boolean>`path <@ ${priorityRoot}::ltree`)
      .executeTakeFirst();

    if (!result) {
      throw new Error(`Focus with key "${update.key}" not found`);
    }
    priorityId = result.id;
  } else {
    priorityId = update.id;
  }

  await plot.validatePriorityAccess(priorityId);

  const dbUpdate: Omit<Database["public"]["Tables"]["priority"]["Update"], "seq"> = {
    updated_by: plot.getUpdatedBy(),
  };

  if (update.title !== undefined) {
    dbUpdate.title = update.title;
  }
  if (update.archived !== undefined) {
    dbUpdate.archived_at = update.archived ? new Date().toISOString() : null;
  }

  const hasScalarUpdates = Object.keys(dbUpdate).length > 1; // more than just updated_by
  if (hasScalarUpdates) {
    await plot.db
      .updateTable("priority")
      .set(dbUpdate as any)
      .where("id", "=", priorityId)
      .execute();
  }
}
