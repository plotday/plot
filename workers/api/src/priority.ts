import { RpcTarget } from "cloudflare:workers";

import type { Database, SupabaseClient } from "@plotday/db";
import type { Priority as IPriority, NewActivity, NewPriority } from "@plotday/agents";

import { create as createActivity } from "./activity";
import path from "path";

export class Priority extends RpcTarget implements IPriority {
  private supabase: SupabaseClient;
  private priorityId: string;
  private id: string;

  constructor(supabase: SupabaseClient, priorityId: string, id: string) {
    super();
    this.supabase = supabase;
    this.priorityId = priorityId;
    this.id = id;
  }

  async createActivity(activity: NewActivity) {
    // Convert NewActivity to database format
    const dbActivity: Database["public"]["Tables"]["activity"]["Insert"] = {
      created_by: this.id,
      priority_id: activity.priorityId || this.priorityId,
      do_at: activity.doOn || null,
      done_at: activity.doneAt ? activity.doneAt.toISOString() : null,
      note: activity.note || null,
      pinned: activity.pinned || false,
    };

    // Handle path generation based on parentId
    if (activity.parentId) {
      // Look up parent activity to get its path
      const parentResult = await this.supabase
        .from("activity")
        .select("path")
        .eq("id", activity.parentId)
        .single();

      if (parentResult.error) {
        throw new Error(
          `Parent activity not found: ${parentResult.error.message}`
        );
      }
      // Generate child path using database function
      const pathResult = await this.supabase.rpc("generate_path", {
        parent: parentResult.data.path,
      });

      if (pathResult.error) {
        throw new Error(`Path generation failed: ${pathResult.error.message}`);
      }

      dbActivity.path = pathResult.data;
    }

    return await createActivity(this.supabase, dbActivity);
  }

  async createPriority(priority: NewPriority) {
    if (!priority.parentId) {
      priority.parentId = this.priorityId
    }
    
    const parentResult = await this.supabase
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
    const pathResult = await this.supabase.rpc("generate_path", {
      parent: parentResult.data.path,
    });

    if (pathResult.error) {
      throw new Error(`Path generation failed: ${pathResult.error.message}`);
    }

    const dbPriority: Database["public"]["Tables"]["priority"]["Insert"] = {
      created_by: parentResult.data.created_by,
      title: priority.title,
      path: pathResult.data
    };
    
    return await create(this.supabase, dbPriority);
  }
}

export async function create(
  supabase: SupabaseClient,
  priority: Database["public"]["Tables"]["priority"]["Insert"]
) {
  const result = await supabase
    .from("priority")
    .insert(priority)
    .select()
    .single();

  if (result.error) {
    throw new Error(`Priority creation failed: ${result.error.message}`);
  }

  return result.data;
}