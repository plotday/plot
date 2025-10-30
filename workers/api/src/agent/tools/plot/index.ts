import {
  type Activity,
  type ActivityMeta,
  type ActivityUpdate,
  type ActorId,
  type NewActivity,
  type NewPriority,
  type Priority,
} from "@plotday/agent/plot";
import {
  ActivityAccess,
  ContactAccess,
  type Plot as IPlot,
  PriorityAccess,
} from "@plotday/agent/tools/plot";
import type { SupabaseClient } from "@plotday/db";

import type { Bindings } from "../../../env";
import { type ActivityItem } from "../../../types";
import { truncateUuidForUpdatedBy } from "../../../utils/uuid";
import { type PermissionFlag, type ToolPermission } from "../../permissions";
import { AI } from "../ai";
import { Tool } from "../tool";
import * as activityOps from "./activity";
import * as contactsOps from "./contacts";
import {
  buildActivityFromDbRecord,
  calculateTagsAdded,
  calculateTagsRemoved,
} from "./db";
import * as intentOps from "./intent";
import * as priorityOps from "./priority";

export type PlotOptions = typeof IPlot.Options;

export class Plot extends Tool implements IPlot {
  public supabase: SupabaseClient;
  public priorityId: string;
  public priorityAgentId: ActorId;
  public plotOptions?: typeof IPlot.Options;
  public env?: Bindings;
  public ai: AI;

  /**
   * Returns permissions required by this Plot tool instance.
   * @param options - Plot tool options
   * @returns Array of ToolPermissions based on configured access levels
   */
  static Permissions(options?: PlotOptions): ToolPermission[] {
    const perms: ToolPermission[] = [];

    if (options?.activity) {
      // Can create new threads
      if (options.activity.access === ActivityAccess.Create) {
        perms.push({
          domain: "plot",
          entity: "thread:new",
          flags: ["write"],
        });
      }

      // Can respond in threads where mentioned
      if (options.activity.intents?.length) {
        perms.push({
          domain: "plot",
          entity: "thread:mentioned",
          flags: ["read", "write", "update"],
        });
      }
    }

    if (options?.priority?.access !== undefined) {
      let flags = [] as PermissionFlag[];
      if (options.priority.access === PriorityAccess.Create) {
        flags = ["write"];
      } else if (options.priority.access === PriorityAccess.Full) {
        flags = ["read", "write", "update"];
      }
      perms.push({
        domain: "plot",
        entity: "priority",
        flags,
      });
    }

    if (options?.contact?.access !== undefined) {
      let flags = [] as PermissionFlag[];
      if (options.contact.access === ContactAccess.Read) {
        flags = ["read"];
      } else if (options.contact.access === ContactAccess.Write) {
        flags = ["read", "write", "update"];
      }
      perms.push({
        domain: "plot",
        entity: "contact",
        flags,
      });
    }

    return perms;
  }

  constructor({
    supabase,
    priorityId,
    priorityAgentId,
    options,
    env,
  }: {
    supabase: SupabaseClient;
    priorityId: string;
    priorityAgentId: string;
    options?: typeof IPlot.Options;
    env: Bindings;
  }) {
    super();
    this.supabase = supabase;
    this.priorityId = priorityId;
    this.priorityAgentId = priorityAgentId as ActorId;
    this.plotOptions = options;
    this.env = env;
    this.ai = new AI({ env, priorityAgentId });
  }

  /**
   * Dispatches activity events to configured callbacks.
   *
   * @param item - Raw activity database record
   * @param previous - Previous activity database record (null for creates)
   * @returns Array of callbacks to invoke in agent worker (empty array if none)
   */
  async dispatch(
    item: ActivityItem,
    previous?: ActivityItem
  ): Promise<Array<{ optionPath: string[]; args: any[] }>> {
    if (!this.plotOptions) return [];

    const callbacks: Array<{ optionPath: string[]; args: any[] }> = [];

    // Determine if this is an update or create
    const isUpdate = !!previous;

    // Build the current activity
    const currentActivity = buildActivityFromDbRecord(item);

    // Dispatch intent matching if agent was mentioned in this thread
    const isMentioned = [
      ...(currentActivity.mentions ?? []),
      ...(currentActivity.threadRoot?.mentions ?? []),
    ].includes(this.priorityAgentId);
    if (isMentioned && !isUpdate) {
      const result = await intentOps.handleIntent(this, currentActivity);
      if (result) {
        callbacks.push(result);
      }
    }

    // Only dispatch activity.updated for updates (not creates) of activities created by this agent
    const createdByThisAgent =
      (item.created_by ?? item.author_id) === this.priorityAgentId;
    if (createdByThisAgent && isUpdate) {
      // Build the previous activity and changes object
      const previousActivity = buildActivityFromDbRecord(previous);
      const changes = {
        previous: previousActivity,
        tagsAdded: calculateTagsAdded(item.tags, previous.tags),
        tagsRemoved: calculateTagsRemoved(item.tags, previous.tags),
      };

      // Check if activity.updated callback exists
      const callback = this.plotOptions?.activity?.updated;
      if (typeof callback === "function") {
        callbacks.push({
          optionPath: ["activity", "updated"],
          args: [currentActivity, changes],
        });
      }
    }

    return callbacks;
  }

  /**
   * Gets the updated_by value for this agent to prevent processing loops.
   * Returns the truncated UUID if valid, otherwise returns undefined.
   */
  getUpdatedBy(): number {
    try {
      return truncateUuidForUpdatedBy(this.priorityAgentId);
    } catch (error) {
      console.warn(
        `Failed to generate updated_by for agent ${this.priorityAgentId}: ${
          error instanceof Error ? error.message : error
        }`
      );
      return 0;
    }
  }

  /**
   * Validates that the given priority ID is within the allowed hierarchy
   * (either the configured priorityId or one of its children)
   */
  async validatePriorityAccess(priorityId: string): Promise<void> {
    if (priorityId === this.priorityId) {
      return; // Direct access to root priority is allowed
    }

    // Check if the priority is a child of the configured priority
    const { data, error } = await this.supabase
      .from("priority_child")
      .select("child_id")
      .eq("priority_id", this.priorityId)
      .eq("child_id", priorityId)
      .single();

    if (error || !data) {
      throw new Error(
        `Access denied: Priority ${priorityId} is not within ${this.priorityId}`
      );
    }
  }

  /**
   * Checks if the agent has the required activity access permission.
   * @throws Error if permission is not granted
   */
  requireActivityAccess(required: ActivityAccess): void {
    const granted = this.plotOptions?.activity?.access;
    if (granted === undefined) {
      throw new Error(
        `Activity access not requested. Required: ${ActivityAccess[required]}`
      );
    }

    // Check if granted permission is sufficient
    // Create includes Respond permissions
    if (
      required === ActivityAccess.Respond &&
      granted >= ActivityAccess.Respond
    ) {
      return;
    }
    if (
      required === ActivityAccess.Create &&
      granted >= ActivityAccess.Create
    ) {
      return;
    }

    throw new Error(
      `Insufficient activity access. Required: ${ActivityAccess[required]}, Granted: ${ActivityAccess[granted]}`
    );
  }

  /**
   * Checks if the agent has the required priority access permission.
   * @throws Error if permission is not granted
   */
  requirePriorityAccess(required: PriorityAccess): void {
    const granted = this.plotOptions?.priority?.access;
    if (granted === undefined) {
      throw new Error(
        `Priority access not requested. Required: ${PriorityAccess[required]}`
      );
    }

    // Check if granted permission is sufficient
    // Full includes Create permissions
    if (
      required === PriorityAccess.Create &&
      granted >= PriorityAccess.Create
    ) {
      return;
    }
    if (required === PriorityAccess.Full && granted >= PriorityAccess.Full) {
      return;
    }

    throw new Error(
      `Insufficient priority access. Required: ${PriorityAccess[required]}, Granted: ${PriorityAccess[granted]}`
    );
  }

  /**
   * Checks if the agent has the required contact access permission.
   * @throws Error if permission is not granted
   */
  requireContactAccess(required: ContactAccess): void {
    const granted = this.plotOptions?.contact?.access;
    if (granted === undefined) {
      throw new Error(
        `Contact access not requested. Required: ${ContactAccess[required]}`
      );
    }

    // Check if granted permission is sufficient
    // Write includes Read permissions
    if (required === ContactAccess.Read && granted >= ContactAccess.Read) {
      return;
    }
    if (required === ContactAccess.Write && granted >= ContactAccess.Write) {
      return;
    }

    throw new Error(
      `Insufficient contact access. Required: ${ContactAccess[required]}, Granted: ${ContactAccess[granted]}`
    );
  }

  /**
   * Validates that the agent has permission to create an activity.
   * - Top-level activities require Create permission
   * - Activities in a thread where the agent was mentioned require Respond permission
   * - Activities in a thread created by the agent require Create permission
   */
  async validateActivityCreateAccess(activity: {
    parent?: { id: string } | null;
  }): Promise<void> {
    // If no parent, this is a top-level activity - requires Create
    if (!activity.parent) {
      this.requireActivityAccess(ActivityAccess.Create);
      return;
    }

    // Fetch the parent activity and thread root (if parent is not root) to check permissions
    const { data: parentActivity, error } = await this.supabase
      .from("activity")
      .select("id, author_id, mentions, path")
      .eq("id", activity.parent.id)
      .single();

    if (error || !parentActivity) {
      throw new Error(`Parent activity not found: ${activity.parent.id}`);
    }

    // Determine if parent is the thread root or if we need to fetch the root
    const pathSegments = String(parentActivity.path).split(".");
    const isParentRoot = pathSegments.length === 1;

    // Get thread root author_id and mentions
    let threadRootAuthorId: string;
    let threadRootMentions: string[];

    if (isParentRoot) {
      // Parent is the thread root
      threadRootAuthorId = parentActivity.author_id;
      threadRootMentions = parentActivity.mentions || [];
    } else {
      // Fetch the thread root
      const rootPath = pathSegments[0];
      const { data: threadRoot, error: threadError } = await this.supabase
        .from("activity")
        .select("id, author_id, mentions")
        .eq("path", rootPath)
        .single();

      if (threadError || !threadRoot) {
        throw new Error(`Failed to fetch thread root`);
      }

      threadRootAuthorId = threadRoot.author_id;
      threadRootMentions = threadRoot.mentions || [];
    }

    // Check if the thread root was created by this agent
    if (threadRootAuthorId === this.priorityAgentId) {
      return;
    }

    // Check if any activity in the thread mentions the agent
    if (
      Array.isArray(threadRootMentions) &&
      threadRootMentions.includes(this.priorityAgentId)
    ) {
      // Agent was mentioned in the thread - requires Respond
      this.requireActivityAccess(ActivityAccess.Respond);
      return;
    }

    // Agent not mentioned and didn't create the thread
    throw new Error(
      `Cannot create activity in thread: agent was not mentioned and did not create the thread`
    );
  }

  /**
   * Validates that the agent has permission to update an activity.
   * - Activities where the agent was mentioned require Respond permission
   * - Activities in a thread created by the agent require Create permission
   */
  async validateActivityUpdateAccess(activityId: string): Promise<void> {
    // Fetch the activity to check author, mentions, and thread
    const { data: activity, error } = await this.supabase
      .from("activity")
      .select("id, author_id, mentions, path")
      .eq("id", activityId)
      .single();

    if (error || !activity) {
      throw new Error(`Activity not found: ${activityId}`);
    }

    // Check if activity mentions the agent
    if (
      activity.mentions &&
      Array.isArray(activity.mentions) &&
      activity.mentions.includes(this.priorityAgentId)
    ) {
      this.requireActivityAccess(ActivityAccess.Respond);
      return;
    }

    // Determine if activity is the thread root or if we need to fetch the root
    const pathSegments = String(activity.path).split(".");
    const isActivityRoot = pathSegments.length === 1;

    // Get thread root author_id and mentions
    let threadRootAuthorId: string;
    let threadRootMentions: string[];

    if (isActivityRoot) {
      // Activity is the thread root
      threadRootAuthorId = activity.author_id;
      threadRootMentions = activity.mentions || [];
    } else {
      // Fetch the thread root
      const rootPath = pathSegments[0];
      const { data: threadRoot, error: threadError } = await this.supabase
        .from("activity")
        .select("id, author_id, mentions")
        .eq("path", rootPath)
        .single();

      if (threadError || !threadRoot) {
        throw new Error(`Failed to fetch thread root`);
      }

      threadRootAuthorId = threadRoot.author_id;
      threadRootMentions = threadRoot.mentions || [];
    }

    // Check if the thread root was created by this agent
    if (threadRootAuthorId === this.priorityAgentId) {
      this.requireActivityAccess(ActivityAccess.Create);
      return;
    }

    // Check if any activity in the thread mentions the agent
    // (thread root mentions are propagated from all children via trigger)
    if (
      Array.isArray(threadRootMentions) &&
      threadRootMentions.includes(this.priorityAgentId)
    ) {
      this.requireActivityAccess(ActivityAccess.Respond);
      return;
    }

    throw new Error(
      `Cannot update activity: agent was not mentioned and did not create the thread`
    );
  }

  // Activity operations
  async createActivity(activity: NewActivity): Promise<Activity> {
    return activityOps.createActivity(this, activity);
  }

  async updateActivity(activity: ActivityUpdate): Promise<void> {
    return activityOps.updateActivity(this, activity);
  }

  async getThread(activity: Activity): Promise<Activity[]> {
    return activityOps.getThread(this, activity);
  }

  async getActivityByMeta(meta: ActivityMeta): Promise<Activity | null> {
    return activityOps.getActivityByMeta(this, meta);
  }

  async createActivities(activities: NewActivity[]): Promise<Activity[]> {
    return activityOps.createActivities(this, activities);
  }

  // Priority operations
  async createPriority(priority: NewPriority): Promise<Priority> {
    return priorityOps.createPriority(this, priority);
  }

  // Contact operations
  async addContacts(
    contacts: Array<{ email: string; name?: string; avatar?: string }>
  ): Promise<void> {
    return contactsOps.addContacts(this, contacts);
  }
}
