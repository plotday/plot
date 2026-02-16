import type { Database } from "@plotday/db";
import {
  type NewPriority,
  type Priority,
  type PriorityUpdate,
  type Uuid,
} from "@plotday/twister/plot";
import { PriorityAccess } from "@plotday/twister/tools/plot";
import { sql } from "kysely";

import { rpc } from "../../../rpc";
import { fromDbPriority } from "./converters";
import type { Plot } from "./index";

export async function createPriority(
  plot: Plot,
  priority: NewPriority
): Promise<Priority & { created: boolean }> {
  // Validate priority create access permissions
  plot.requirePriorityAccess(PriorityAccess.Create);

  // If a key is provided, check if the priority already exists (idempotent upsert)
  if ("key" in priority && priority.key) {
    const existing = await getPriority(plot, { key: priority.key });
    if (existing) {
      return { ...existing, created: false };
    }
  }

  // Determine parent priority ID
  let parentId: string;

  if (priority.parent) {
    if ("key" in priority.parent) {
      // Look up parent by key, scoped to the twist's priority root
      const priorityRoot = await plot.getPriorityRoot();
      const result = await plot.db
        .selectFrom("priority")
        .select("id")
        .where("key", "=", priority.parent.key)
        .where(sql<boolean>`path <@ ${priorityRoot}::ltree`)
        .executeTakeFirst();

      if (!result) {
        throw new Error(
          `Parent priority with key "${priority.parent.key}" not found in priority tree`
        );
      }

      parentId = result.id;
    } else {
      parentId = priority.parent.id;
    }
  } else {
    // Default to twist's priority
    parentId = plot.priorityId;
  }

  // Validate access to the parent priority
  await plot.validatePriorityAccess(parentId);

  const parentResult = await plot.db
    .selectFrom("priority")
    .select(["path", "created_by"])
    .where("id", "=", parentId)
    .executeTakeFirstOrThrow();

  // Generate child path using database function
  // rpc() unwraps scalar results, so we get the path string directly
  const path = await rpc(plot.db, "generate_path", {
    parent: parentResult.path,
  });

  // Build the priority insert object
  const dbPriority: Database["public"]["Tables"]["priority"]["Insert"] = {
    created_by: parentResult.created_by,
    title: priority.title,
    path: path as string,
    updated_by: plot.getUpdatedBy(),
    sync_depth: plot.syncDepth + 1,
  };

  // If an ID was provided, use it
  if ("id" in priority && priority.id) {
    dbPriority.id = priority.id;
  }

  // If a key was provided, set it on the priority
  if ("key" in priority && priority.key) {
    dbPriority.key = priority.key;
  }

  // If a color was provided, set it on the priority
  if (priority.color !== undefined) {
    dbPriority.color = priority.color;
  }

  const result = await plot.db
    .insertInto("priority")
    .values(dbPriority as any)
    .returningAll()
    .executeTakeFirstOrThrow();

  return { ...fromDbPriority(result), created: true };
}

export async function getPriority(
  plot: Plot,
  priority: { id: Uuid } | { key: string }
): Promise<Priority | null> {
  // Validate priority access permissions
  plot.requirePriorityAccess(PriorityAccess.Create);

  let dbPriority;

  if ("key" in priority) {
    // Look up priority by key in priority table, scoped to twist's priority root
    const priorityRoot = await plot.getPriorityRoot();
    const result = await plot.db
      .selectFrom("priority")
      .select(["id", "title", "archived_at", "key", "color"])
      .where("key", "=", priority.key)
      .where(sql<boolean>`path <@ ${priorityRoot}::ltree`)
      .executeTakeFirst();

    if (!result) {
      return null;
    }

    dbPriority = result;
  } else {
    // Look up priority by ID
    const result = await plot.db
      .selectFrom("priority")
      .select(["id", "title", "archived_at", "key", "color"])
      .where("id", "=", priority.id)
      .executeTakeFirst();

    if (!result) {
      return null;
    }

    dbPriority = result;
  }

  // Validate that the twist has access to this priority
  try {
    await plot.validatePriorityAccess(dbPriority.id);
  } catch {
    return null;
  }

  return fromDbPriority(dbPriority);
}

export async function updatePriority(
  plot: Plot,
  update: PriorityUpdate
): Promise<void> {
  // Validate priority access permissions
  plot.requirePriorityAccess(PriorityAccess.Create);

  // First look up the priority to get its ID if key was provided
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
      throw new Error(`Priority with key "${update.key}" not found in priority tree`);
    }

    priorityId = result.id;
  } else {
    priorityId = update.id;
  }

  // Validate access to the priority
  await plot.validatePriorityAccess(priorityId);

  // Build the update object with only the fields that were provided
  const dbUpdate: Database["public"]["Tables"]["priority"]["Update"] = {
    updated_by: plot.getUpdatedBy(),
  };

  if (update.title !== undefined) {
    dbUpdate.title = update.title;
  }

  if (update.archived !== undefined) {
    dbUpdate.archived_at = update.archived ? new Date().toISOString() : null;
  }

  await plot.db
    .updateTable("priority")
    .set(dbUpdate as any)
    .where("id", "=", priorityId)
    .execute();
}
