import { type Database, type SupabaseClient } from "@plotday/db";
import {
  type Activity,
  type ActivityMeta,
  type ActivityUpdate,
  type Actor,
  type ActorId,
  type NewActivity,
  type NewActivityWithNotes,
  type NewNote,
  type NewPriority,
  type Note,
  type NoteUpdate,
  type Priority,
  type PriorityUpdate,
  Uuid,
} from "@plotday/twister/plot";
import {
  ActivityAccess,
  ContactAccess,
  type Plot as IPlot,
  PriorityAccess,
} from "@plotday/twister/tools/plot";

import type { Bindings } from "../../../env";
import { type ActivityItem, type NoteItem } from "../../../types";
import { createLogger } from "../../../utils/logger";
import { truncateUuidForUpdatedBy } from "../../../utils/uuid";
import { type PermissionFlag, type ToolPermission } from "../../permissions";
import { AI } from "../ai";
import { Tool } from "../tool";
import * as activityOps from "./activity";
import * as contactsOps from "./contacts";
import { fromDbActivity } from "./converters";
import {
  buildActivityFromDbRecord,
  buildNoteFromDbRecord,
  calculateTagsAdded,
  calculateTagsRemoved,
} from "./db";
import * as intentOps from "./intent";
import * as priorityOps from "./priority";

export type PlotOptions = typeof IPlot.Options;

/**
 * Worker-level cache for activity metadata to avoid database queries.
 * This cache persists across HTTP requests within the same worker instance,
 * allowing dispatch() to cache data that updateActivity() can later use.
 *
 * Key format: `${activityId}:${priorityTwistId}`
 * Entries expire after 30 seconds to prevent unbounded growth.
 */
const ACTIVITY_METADATA_CACHE = new Map<
  string,
  {
    created_by: string | null;
    mentions: string[] | null;
    priority_id: string;
    triggering_note_mentions?: string[] | null;
    timestamp: number;
  }
>();

const CACHE_TTL_MS = 30_000; // 30 seconds

/**
 * Cleans up expired entries from the worker-level cache.
 * Called periodically to prevent memory leaks.
 */
function cleanupExpiredCacheEntries(): void {
  const now = Date.now();
  for (const [key, value] of ACTIVITY_METADATA_CACHE.entries()) {
    if (now - value.timestamp > CACHE_TTL_MS) {
      ACTIVITY_METADATA_CACHE.delete(key);
    }
  }
}

/**
 * Getter for the worker-level activity metadata cache.
 * Exported to allow other modules (e.g., activity.ts) to access the cache.
 */
export function getActivityCache() {
  return ACTIVITY_METADATA_CACHE;
}

/**
 * Worker-level cache for twist definition IDs to avoid database queries.
 * This cache persists across HTTP requests within the same worker instance.
 *
 * Key format: `${priorityTwistId}` (the priority_twist.id)
 * Value: `twist_id` from priority_twist table
 * Entries expire after 5 minutes to prevent unbounded growth.
 */
const TWIST_ID_CACHE = new Map<
  string,
  {
    twist_id: number;
    timestamp: number;
  }
>();

const TWIST_ID_CACHE_TTL_MS = 300_000; // 5 minutes

/**
 * Cleans up expired entries from the twist ID cache.
 */
function cleanupExpiredTwistIdCache(): void {
  const now = Date.now();
  for (const [key, value] of TWIST_ID_CACHE.entries()) {
    if (now - value.timestamp > TWIST_ID_CACHE_TTL_MS) {
      TWIST_ID_CACHE.delete(key);
    }
  }
}

export type DispatchItem =
  | { itemType: "activity"; item: ActivityItem; previous?: ActivityItem; syncDepth?: number }
  | { itemType: "note"; item: NoteItem; previous?: NoteItem; syncDepth?: number };

export class Plot extends Tool implements IPlot {
  public supabase: SupabaseClient;
  public priorityId: string;
  public priorityTwistId: ActorId;
  public plotOptions?: typeof IPlot.Options;
  public env: Bindings;
  public ai: AI;
  public syncDepth: number = 1;
  private _actor?: Actor;
  private _twistId?: number;

  /**
   * Returns permissions required by this Plot tool instance.
   * @param options - Plot tool options
   * @returns Array of ToolPermissions based on configured access levels
   */
  static Permissions(options?: PlotOptions): ToolPermission[] {
    const perms: ToolPermission[] = [];

    if (options?.activity) {
      // Can create new activities
      if (options.activity.access === ActivityAccess.Create) {
        perms.push({
          domain: "plot",
          entity: "activity:new",
          flags: ["write"],
        });
      }

      // Can respond in activities where mentioned
      if (options.note?.intents?.length) {
        perms.push({
          domain: "plot",
          entity: "activity:mentioned",
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
    priorityTwistId,
    options,
    env,
  }: {
    supabase: SupabaseClient;
    priorityId: string;
    priorityTwistId: string;
    options?: typeof IPlot.Options;
    env: Bindings;
  }) {
    super();
    this.supabase = supabase;
    this.priorityId = priorityId;
    this.priorityTwistId = priorityTwistId as ActorId;
    this.plotOptions = options;
    this.env = env;
    this.ai = new AI({ env, priorityTwistId });
  }

  /**
   * Gets the Actor for this twist, fetching and caching it on first access.
   * @returns The Actor object for the twist
   */
  async getActor(): Promise<Actor> {
    if (!this._actor) {
      const { data, error } = await this.supabase
        .from("actor")
        .select("id, name, type, email")
        .eq("id", this.priorityTwistId)
        .single();

      if (error || !data) {
        throw new Error(
          `Failed to fetch twist actor: ${error?.message ?? "Actor not found"}`
        );
      }

      this._actor = {
        id: data.id as ActorId,
        type: data.type as any,
        name: data.name ?? null,
        email: data.email ?? undefined,
      };
    }

    return this._actor;
  }

  /**
   * Gets the twist definition ID for a given priority_twist ID.
   * Uses worker-level cache to avoid repeated database queries.
   * @param priorityTwistId - The priority_twist.id to look up
   * @returns The twist_id (twist definition ID) or null if not found
   */
  async getTwistId(priorityTwistId: string): Promise<number | null> {
    // Check worker-level cache first
    const cached = TWIST_ID_CACHE.get(priorityTwistId);
    if (cached && Date.now() - cached.timestamp < TWIST_ID_CACHE_TTL_MS) {
      return cached.twist_id;
    }

    // Query database
    const { data, error } = await this.supabase
      .from("priority_twist")
      .select("twist_id")
      .eq("id", priorityTwistId)
      .single();

    if (error || !data) {
      return null;
    }

    // Cache the result
    TWIST_ID_CACHE.set(priorityTwistId, {
      twist_id: data.twist_id,
      timestamp: Date.now(),
    });

    // Periodically clean up expired entries
    if (TWIST_ID_CACHE.size > 100) {
      cleanupExpiredTwistIdCache();
    }

    return data.twist_id;
  }

  /**
   * Checks if the given priority_twist ID belongs to the same twist definition
   * as the current twist instance.
   * @param priorityTwistId - The priority_twist.id to check
   * @returns True if both belong to the same twist definition, false otherwise
   */
  async isSameTwistDefinition(priorityTwistId: string): Promise<boolean> {
    // Get the current twist's definition ID
    if (!this._twistId) {
      const twistId = await this.getTwistId(this.priorityTwistId);
      if (!twistId) {
        return false;
      }
      this._twistId = twistId;
    }

    // Get the other twist's definition ID
    const otherTwistId = await this.getTwistId(priorityTwistId);
    if (!otherTwistId) {
      return false;
    }

    return this._twistId === otherTwistId;
  }

  /**
   * Dispatches activity and note events to configured callbacks.
   *
   * @param dispatchItem - Discriminated union containing either activity or note data
   * @returns Array of callbacks to invoke in twist worker (empty array if none)
   */
  async dispatch(
    dispatchItem: DispatchItem
  ): Promise<Array<{ optionPath: string[]; args: any[] }>> {
    if (!this.plotOptions) return [];

    // Set sync depth from dispatch context (defaults to 1 if not provided)
    this.syncDepth = dispatchItem.syncDepth ?? 1;

    const callbacks: Array<{ optionPath: string[]; args: any[] }> = [];

    // Handle note items
    if (dispatchItem.itemType === "note") {
      const { item, previous } = dispatchItem;
      const isUpdate = !!previous;

      // Cache the triggering note's mentions with the parent activity
      // This allows validation to check if the twist was mentioned in the note
      // that triggered the callback, even if the activity's calculated mentions
      // field hasn't been updated yet (race condition)
      const cacheKey = `${item.activity_id}:${this.priorityTwistId}`;
      const existing = ACTIVITY_METADATA_CACHE.get(cacheKey);

      ACTIVITY_METADATA_CACHE.set(cacheKey, {
        created_by: existing?.created_by ?? null,
        mentions: existing?.mentions ?? null,
        priority_id: existing?.priority_id ?? item.priority_id,
        triggering_note_mentions: item.mentions,
        timestamp: Date.now(),
      });

      // Build the current note
      const currentNote = buildNoteFromDbRecord(item);

      // Dispatch intent matching if twist was mentioned in this note and it's a create
      const isMentioned = (currentNote.mentions ?? []).includes(
        this.priorityTwistId
      );
      if (isMentioned && !isUpdate) {
        const result = await intentOps.handleIntent(this, currentNote);
        if (result) {
          callbacks.push(result);
        }
      }

      // Dispatch note.created callback for new notes on activities created by this twist
      const isCreate = !isUpdate;
      if (isCreate) {
        // Check if parent activity was created by this twist
        const activityMetadata = ACTIVITY_METADATA_CACHE.get(cacheKey);
        const activityCreatedByThisTwist =
          activityMetadata?.created_by === this.priorityTwistId;

        // Check if note was created by this twist
        const noteCreatedByThisTwist = item.created_by === this.priorityTwistId;

        // Only dispatch if activity owned by twist AND note NOT created by twist
        // This prevents infinite loops when twist creates notes on its own activities
        if (activityCreatedByThisTwist && !noteCreatedByThisTwist) {
          const callback = this.plotOptions?.note?.created;
          if (typeof callback === "function") {
            callbacks.push({
              optionPath: ["note", "created"],
              args: [currentNote],
            });
          }
        }
      }
    }

    // Handle activity items
    if (dispatchItem.itemType === "activity") {
      const { item, previous } = dispatchItem;
      const isUpdate = !!previous;

      // Cache activity data in worker-level cache to avoid database queries
      // in subsequent RPC calls (e.g., when twist callback calls updateActivity)
      const cacheKey = `${item.id}:${this.priorityTwistId}`;
      const cacheData = {
        created_by: item.created_by ?? item.author_id,
        mentions: item.mentions,
        priority_id: item.priority_id,
        timestamp: Date.now(),
      };
      ACTIVITY_METADATA_CACHE.set(cacheKey, cacheData);

      // Periodically clean up expired entries
      if (ACTIVITY_METADATA_CACHE.size > 100) {
        cleanupExpiredCacheEntries();
      }

      // Build the current activity
      const currentActivity = buildActivityFromDbRecord(item);

      // Only dispatch activity.updated for updates (not creates) of activities created by this twist
      const createdByThisTwist =
        (item.created_by ?? item.author_id) === this.priorityTwistId;
      if (createdByThisTwist && isUpdate) {
        // Build the previous activity
        const previousActivity = buildActivityFromDbRecord(previous);

        // Calculate ActivityUpdate with only changed fields
        const update: ActivityUpdate = {
          id: currentActivity.id,
        };

        // Check each field for changes
        if (currentActivity.type !== previousActivity.type) {
          update.type = currentActivity.type;
        }
        if (currentActivity.title !== previousActivity.title) {
          update.title = currentActivity.title;
        }
        if (currentActivity.assignee?.id !== previousActivity.assignee?.id) {
          update.assignee = currentActivity.assignee;
        }
        if (currentActivity.start !== previousActivity.start) {
          update.start = currentActivity.start;
        }
        if (currentActivity.end !== previousActivity.end) {
          update.end = currentActivity.end;
        }
        if (currentActivity.done !== previousActivity.done) {
          update.done = currentActivity.done;
        }
        if (currentActivity.draft !== previousActivity.draft) {
          update.draft = currentActivity.draft;
        }
        if (currentActivity.private !== previousActivity.private) {
          update.private = currentActivity.private;
        }

        // Build changes object with both current and previous
        const changes = {
          update,
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
    }

    return callbacks;
  }

  /**
   * Gets the updated_by value for this twist to prevent processing loops.
   * Returns the truncated UUID if valid, otherwise returns undefined.
   */
  getUpdatedBy(): number {
    try {
      return truncateUuidForUpdatedBy(this.priorityTwistId);
    } catch (error) {
      const logger = createLogger({ priority_twist_id: this.priorityTwistId });
      logger.warn("Failed to generate updated_by for twist", {
        error_message: error instanceof Error ? error.message : String(error),
      });
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
   * Checks if the twist has the required activity access permission.
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
   * Checks if the twist has the required priority access permission.
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
   * Checks if the twist has the required contact access permission.
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
   * Validates that the twist has permission to create an activity.
   * - Top-level activities require Create permission
   * - Activities in a thread where the twist was mentioned require Respond permission
   * - Activities in a thread created by the twist require Create permission
   */
  async validateActivityCreateAccess(_activity: NewActivity): Promise<void> {
    this.requireActivityAccess(ActivityAccess.Create);
  }

  /**
   * Validates that the twist has permission to create a note.
   * - Notes on activities where the twist was mentioned require Respond permission
   * - Notes on activities created by the twist require Create permission
   */
  async validateNoteCreateAccess(activityId: string): Promise<void> {
    // Fetch the parent activity to check permissions
    const { data: activity, error } = await this.supabase
      .from("activity_x")
      .select("id, author_id, created_by, mentions")
      .eq("id", activityId)
      .single();

    if (error || !activity) {
      throw new Error(`Activity not found: ${activityId}`);
    }

    // Check if the activity was created by this twist
    if (activity.created_by === this.priorityTwistId) {
      return;
    }

    // Check if the activity mentions the twist
    if (
      Array.isArray(activity.mentions) &&
      activity.mentions.includes(this.priorityTwistId)
    ) {
      // Twist was mentioned in the activity - requires Respond
      this.requireActivityAccess(ActivityAccess.Respond);
      return;
    }

    // Twist not mentioned and didn't create the activity
    throw new Error(
      `Cannot create note on activity: twist was not mentioned and did not create the activity`
    );
  }

  /**
   * Validates that the twist has permission to update an activity.
   * - Activities where the twist was mentioned require Respond permission
   * - Activities created by the twist require Create permission
   * - Activities created by another instance of the same twist require Create permission
   *
   * @param activityId - The activity ID to validate access for
   * @param cachedData - Optional cached data to avoid database query
   */
  async validateActivityUpdateAccess(
    activityId: string,
    cachedData?: { created_by: string | null; mentions: string[] | null }
  ): Promise<void> {
    let created_by: string | null;
    let mentions: string[] | null;

    // Check worker-level cache first, then optional parameter, then query database
    const cacheKey = `${activityId}:${this.priorityTwistId}`;
    const workerCached = ACTIVITY_METADATA_CACHE.get(cacheKey);
    const cached = cachedData ?? workerCached;

    if (cached) {
      created_by = cached.created_by;
      mentions = cached.mentions;
    } else {
      // Fetch the activity to check author and mentions
      const { data: activity, error } = await this.supabase
        .from("activity_x")
        .select("id, author_id, created_by, mentions")
        .eq("id", activityId)
        .single();

      if (error || !activity) {
        throw new Error(`Activity not found: ${activityId}`);
      }

      created_by = activity.created_by;
      mentions = activity.mentions;
    }

    // Check if the activity was created by this twist
    if (created_by === this.priorityTwistId) {
      this.requireActivityAccess(ActivityAccess.Create);
      return;
    }

    // Check if activity mentions the twist
    if (
      mentions &&
      Array.isArray(mentions) &&
      mentions.includes(this.priorityTwistId)
    ) {
      this.requireActivityAccess(ActivityAccess.Respond);
      return;
    }

    // Check if triggering note mentioned the twist
    // This handles race conditions where a note with a mention triggers a callback
    // but the activity's calculated mentions field hasn't been updated yet
    if (
      workerCached?.triggering_note_mentions &&
      Array.isArray(workerCached.triggering_note_mentions) &&
      workerCached.triggering_note_mentions.includes(this.priorityTwistId)
    ) {
      this.requireActivityAccess(ActivityAccess.Respond);
      return;
    }

    // Fallback: Check if activity was created by another instance of the same twist
    // This allows twists to update activities created by any instance of the same twist,
    // which is useful when activities are moved between priorities or when multiple
    // instances of the same twist are installed in different priorities
    if (created_by && (await this.isSameTwistDefinition(created_by))) {
      this.requireActivityAccess(ActivityAccess.Create);
      // Skip priority validation - twist can access activities it created regardless of priority
      return;
    }

    throw new Error(
      `Cannot update activity: twist was not mentioned and did not create the activity`
    );
  }

  // Activity operations
  async createActivity(
    activity: NewActivity | NewActivityWithNotes
  ): Promise<Activity> {
    return activityOps.createActivity(this, activity);
  }

  async updateActivity(activity: ActivityUpdate): Promise<void> {
    return activityOps.updateActivity(this, activity);
  }

  async getActivity(
    activity: { id: Uuid } | { source: string }
  ): Promise<Activity | null> {
    return activityOps.getActivity(this, activity);
  }

  async createActivities(
    activities: NewActivity[]
  ): Promise<Activity[]> {
    return activityOps.createActivities(this, activities);
  }

  // Priority operations
  async createPriority(priority: NewPriority): Promise<Priority> {
    return priorityOps.createPriority(this, priority);
  }

  async getPriority(
    priority: { id: Uuid } | { key: string }
  ): Promise<Priority | null> {
    return priorityOps.getPriority(this, priority);
  }

  async updatePriority(update: PriorityUpdate): Promise<void> {
    return priorityOps.updatePriority(this, update);
  }

  // Contact operations
  async addContacts(
    contacts: Array<{ email: string; name?: string; avatar?: string }>
  ): Promise<Actor[]> {
    return contactsOps.addContacts(this, contacts);
  }

  async getActors(ids: ActorId[]): Promise<Actor[]> {
    return contactsOps.getActors(this, ids);
  }

  // Note operations
  async getNotes(activity: Activity): Promise<Note[]> {
    return activityOps.getNotes(this, activity);
  }

  async getNote(
    note: { id: Uuid } | { key: string }
  ): Promise<Note | null> {
    return activityOps.getNote(this, note);
  }

  async createNote(
    note: NewNote,
    skipActivityRead = false
  ): Promise<Note> {
    return activityOps.createNote(this, note, skipActivityRead);
  }

  async createNotes(notes: NewNote[]): Promise<Note[]> {
    return activityOps.createNotes(this, notes);
  }

  async updateNote(note: NoteUpdate): Promise<void> {
    return activityOps.updateNote(this, note);
  }
}
