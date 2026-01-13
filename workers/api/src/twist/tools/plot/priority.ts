import type { Database } from "@plotday/db";
import {
  type NewPriority,
  type Priority,
  type PriorityUpdate,
  type Uuid,
} from "@plotday/twister/plot";
import { PriorityAccess } from "@plotday/twister/tools/plot";

import { fromDbPriority } from "./converters";
import type { Plot } from "./index";

export async function createPriority(
  plot: Plot,
  priority: NewPriority
): Promise<Priority> {
  // Validate priority create access permissions
  plot.requirePriorityAccess(PriorityAccess.Create);

  // Determine parent priority ID
  let parentId: string;

  if (priority.parent) {
    if ("key" in priority.parent) {
      // Look up parent by key, scoped to the twist's priority root
      const priorityRoot = await plot.getPriorityRoot();
      const result = await plot.supabase
        .from("priority")
        .select("id")
        .eq("key", priority.parent.key)
        .filter("path", "cd", priorityRoot)
        .single();

      if (result.error || !result.data) {
        throw new Error(
          `Parent priority with key "${priority.parent.key}" not found in priority tree`
        );
      }

      parentId = result.data.id;
    } else {
      parentId = priority.parent.id;
    }
  } else {
    // Default to twist's priority
    parentId = plot.priorityId;
  }

  // Validate access to the parent priority
  await plot.validatePriorityAccess(parentId);

  const parentResult = await plot.supabase
    .from("priority")
    .select("path, created_by")
    .eq("id", parentId)
    .single();

  if (parentResult.error) {
    throw new Error(`Parent priority not found: ${parentResult.error.message}`);
  }

  // Generate child path using database function
  const pathResult = await plot.supabase.rpc("generate_path", {
    parent: parentResult.data.path,
  });

  if (pathResult.error) {
    throw new Error(`Path generation failed: ${pathResult.error.message}`);
  }

  // Build the priority insert object
  const dbPriority: Database["public"]["Tables"]["priority"]["Insert"] = {
    created_by: parentResult.data.created_by,
    title: priority.title,
    path: pathResult.data,
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

  const result = await plot.supabase
    .from("priority")
    .insert(dbPriority)
    .select()
    .single();

  if (result.error) {
    throw new Error(`Priority creation failed: ${result.error.message}`);
  }

  return fromDbPriority(result.data);
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
    const result = await plot.supabase
      .from("priority")
      .select("id, title, archived_at, key")
      .eq("key", priority.key)
      .filter("path", "cd", priorityRoot)
      .single();

    if (result.error || !result.data) {
      return null;
    }

    dbPriority = result.data;
  } else {
    // Look up priority by ID
    const result = await plot.supabase
      .from("priority")
      .select("id, title, archived_at, key")
      .eq("id", priority.id)
      .single();

    if (result.error) {
      return null;
    }

    dbPriority = result.data;
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
    const result = await plot.supabase
      .from("priority")
      .select("id")
      .eq("key", update.key)
      .filter("path", "cd", priorityRoot)
      .single();

    if (result.error || !result.data) {
      throw new Error(`Priority with key "${update.key}" not found in priority tree`);
    }

    priorityId = result.data.id;
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

  const result = await plot.supabase
    .from("priority")
    .update(dbUpdate)
    .eq("id", priorityId);

  if (result.error) {
    throw new Error(`Priority update failed: ${result.error.message}`);
  }
}
