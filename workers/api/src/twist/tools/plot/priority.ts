import type { Database } from "@plotday/db";
import { type NewPriority, type Priority } from "@plotday/twister/plot";
import { PriorityAccess } from "@plotday/twister/tools/plot";

import type { Plot } from "./index";
import { fromDbPriority } from "./converters";

export async function createPriority(
  plot: Plot,
  priority: NewPriority
): Promise<Priority> {
  // Validate priority create access permissions
  plot.requirePriorityAccess(PriorityAccess.Create);

  if (!priority.parentId) {
    priority.parentId = plot.priorityId;
  }

  // Validate access to the parent priority
  await plot.validatePriorityAccess(priority.parentId);

  const parentResult = await plot.supabase
    .from("priority")
    .select("path, created_by")
    .eq("id", priority.parentId)
    .single();

  if (parentResult.error) {
    throw new Error(
      `Parent priority not found: ${parentResult.error.message}`
    );
  }

  // Generate child path using database function
  const pathResult = await plot.supabase.rpc("generate_path", {
    parent: parentResult.data.path,
  });

  if (pathResult.error) {
    throw new Error(`Path generation failed: ${pathResult.error.message}`);
  }

  const dbPriority: Database["public"]["Tables"]["priority"]["Insert"] = {
    created_by: parentResult.data.created_by,
    title: priority.title,
    path: pathResult.data,
    updated_by: plot.getUpdatedBy(),
  };

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
