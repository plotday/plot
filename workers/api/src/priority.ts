import { RpcTarget } from "cloudflare:workers";

import type { Database, SupabaseClient } from "@plotday/db";
import type { Priority as IPriority, NewActivity } from "@plotday/agents";

import { create as createActivity } from "./activity";

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
      priority_id: this.priorityId,
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
}