import { RpcTarget } from "cloudflare:workers";

import type { Activity, Priority } from "@plotday/agents/sdk";
import type {
  Plot as IPlot,
  NewActivity,
  NewPriority,
} from "@plotday/agents/tools/plot";
import { type Database, type SupabaseClient } from "@plotday/db";

import { create as createActivity } from "../.././activity";

function fromDbActivity(
  dbActivity: Database["public"]["Tables"]["activity"]["Row"]
): Activity {
  return {
    id: dbActivity.id,
    createdBy: dbActivity.created_by,
    doOn: dbActivity.do_on || undefined,
    doneAt: dbActivity.done_at ? new Date(dbActivity.done_at) : undefined,
    note: dbActivity.note || undefined,
    title: dbActivity.title || undefined,
    priorityId: dbActivity.priority_id,
    path: String(dbActivity.path),
    pinned: dbActivity.pinned,
  };
}

function fromDbPriority(
  dbPriority: Database["public"]["Tables"]["priority"]["Row"]
): Priority {
  return {
    id: dbPriority.id,
    title: dbPriority.title,
  };
}

export class Plot extends RpcTarget implements IPlot {
  private supabase: SupabaseClient;
  private priorityId: string;
  private priorityAgentId: string;
  public config: Record<string, string>;

  constructor({
    supabase,
    priorityId,
    priorityAgentId,
    config,
  }: {
    supabase: SupabaseClient;
    priorityId: string;
    priorityAgentId: string;
    config?: Record<string, string>;
  }) {
    super();
    this.supabase = supabase;
    this.priorityId = priorityId;
    this.priorityAgentId = priorityAgentId;
    this.config = config || {};
  }

  async createActivity(activity: NewActivity): Promise<Activity> {
    // Convert NewActivity to database format
    const dbActivity: Database["public"]["Tables"]["activity"]["Insert"] = {
      created_by: this.priorityAgentId,
      priority_id: activity.priorityId || this.priorityId,
      do_on: activity.doOn || null,
      done_at: activity.doneAt ? activity.doneAt.toISOString() : null,
      title: activity.title || null,
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

    const dbResult = await createActivity(this.supabase, dbActivity);
    return fromDbActivity(dbResult);
  }

  async getActivities(activity: Activity): Promise<Activity[]> {
    try {
      const { data, error } = await this.supabase
        .from("activity")
        .select()
        .eq("priority_id", activity.priorityId)
        .filter("path", "cd", activity.path.split(".")[0])
        .order("created_at");
      if (error) {
        console.error(error);
        throw error;
      }
      return data.map(fromDbActivity);
    } catch (err) {
      console.error("Failed to get siblings and parents:", err);
      throw err;
    }
  }

  async createPriority(priority: NewPriority): Promise<Priority> {
    if (!priority.parentId) {
      priority.parentId = this.priorityId;
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
      path: pathResult.data,
    };

    const result = await this.supabase
      .from("priority")
      .insert(dbPriority)
      .select()
      .single();

    if (result.error) {
      throw new Error(`Priority creation failed: ${result.error.message}`);
    }

    return fromDbPriority(result.data);
  }
}
