import type { Kysely } from "kysely";

import {
  type Activity,
  type ActivityUpdate,
  type Actor,
  type ActorId,
  type NewActivity,
  type NewActivityWithNotes,
  type NewContact,
  type NewNote,
  type NewPriority,
  type Note,
  type NoteUpdate,
  type Priority,
  type PriorityUpdate,
  type Uuid,
} from "@plotday/twister/plot";
import { Tag } from "@plotday/twister/tag";
import {
  ActivityAccess,
  ContactAccess,
  type Plot as IPlot,
  PriorityAccess,
} from "@plotday/twister/tools/plot";
import { createLogger } from "@plotday/worker-util";

import type { DB } from "../../../db-types";
import type { Bindings } from "../../../env";
import { rpc, rpcUser } from "../../../rpc";
import { disposeRpc } from "../../../utils/rpc";
import { truncateUuidForUpdatedBy } from "../../../utils/uuid";
import { type PermissionFlag, type ToolPermission } from "../../permissions";
import type { EnrichedActivity, EnrichedNote } from "../../view-types";
import { AI } from "../ai";
import { Tool } from "../tool";
import * as activityOps from "./activity";
import * as contactsOps from "./contacts";
import { buildActivityFromDbRecord, buildNoteFromDbRecord } from "./db";
import * as intentOps from "./intent";
import * as priorityOps from "./priority";

export type PlotOptions = typeof IPlot.Options;

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
  | {
      itemType: "activity";
      item: EnrichedActivity;
      isCreate?: boolean;
      syncDepth?: number;
      changes?: {
        tagsAdded: Record<number, string[]>;
        tagsRemoved: Record<number, string[]>;
        occurrence?: { occurrence: Date | string };
      };
    }
  | {
      itemType: "note";
      item: EnrichedNote;
      isCreate?: boolean;
      syncDepth?: number;
    };

export class Plot extends Tool implements IPlot {
  public db: Kysely<DB>;
  public priorityId: string;
  public priorityTwistId: ActorId;
  public plotOptions?: typeof IPlot.Options;
  public env: Bindings;
  public ai: AI;
  public syncDepth: number = 1;
  private _actor?: Actor;
  private _twistId?: number;
  private _userId?: string;
  private _priorityRoot?: string;

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
    db,
    priorityId,
    priorityTwistId,
    options,
    env,
  }: {
    db: Kysely<DB>;
    priorityId: string;
    priorityTwistId: string;
    options?: typeof IPlot.Options;
    env: Bindings;
  }) {
    super();
    this.db = db;
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
      try {
        const data = await this.db
          .selectFrom("actor")
          .select(["id", "name", "type", "email"])
          .where("id", "=", this.priorityTwistId)
          .executeTakeFirstOrThrow();

        this._actor = {
          id: data.id as ActorId,
          type: data.type as any,
          name: data.name ?? null,
          email: data.email ?? undefined,
        };
      } catch (error) {
        throw new Error(
          `Failed to fetch twist actor: ${error instanceof Error ? error.message : "Actor not found"}`
        );
      }
    }

    return this._actor;
  }

  /**
   * Gets the user ID who owns this twist (from priority_twist.owner_id).
   * Fetches and caches it on first access.
   * @returns The user ID
   * @throws Error if the owner_id cannot be fetched
   */
  async getUserId(): Promise<string> {
    if (!this._userId) {
      try {
        const data = await this.db
          .selectFrom("priority_twist")
          .select("owner_id")
          .where("id", "=", this.priorityTwistId)
          .executeTakeFirstOrThrow();

        if (!data.owner_id) {
          throw new Error("No owner_id found");
        }

        this._userId = data.owner_id;
      } catch (error) {
        throw new Error(
          `Failed to fetch user ID for twist: ${
            error instanceof Error ? error.message : "No owner_id found"
          }`
        );
      }
    }

    return this._userId!;
  }

  /**
   * Gets the root path component of the priority where this twist is installed.
   * This is used for scoping key lookups to the correct priority tree.
   * Fetches and caches it on first access.
   * @returns The priority root as a string (first level of the ltree path)
   * @throws Error if the priority path cannot be fetched
   */
  async getPriorityRoot(): Promise<string> {
    if (!this._priorityRoot) {
      try {
        const data = await this.db
          .selectFrom("priority")
          .select("path")
          .where("id", "=", this.priorityId)
          .executeTakeFirstOrThrow();

        if (!data.path) {
          throw new Error("No path found");
        }

        // Extract the first level of the ltree path (the root)
        // For a path like "work.projects.alpha", this returns "work"
        const pathParts = (data.path as string).split(".");
        this._priorityRoot = pathParts[0]!;
      } catch (error) {
        throw new Error(
          `Failed to fetch priority path for twist: ${
            error instanceof Error ? error.message : "No path found"
          }`
        );
      }
    }

    return this._priorityRoot;
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
    const data = await this.db
      .selectFrom("priority_twist")
      .select("twist_id")
      .where("id", "=", priorityTwistId)
      .executeTakeFirst();

    if (!data) {
      return null;
    }

    const twistId = Number(data.twist_id);

    // Cache the result
    TWIST_ID_CACHE.set(priorityTwistId, {
      twist_id: twistId,
      timestamp: Date.now(),
    });

    // Periodically clean up expired entries
    if (TWIST_ID_CACHE.size > 100) {
      cleanupExpiredTwistIdCache();
    }

    return twistId;
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
    const logger = createLogger({ priority_twist_id: this.priorityTwistId });

    if (!this.plotOptions) {
      return [];
    }

    // Set sync depth from dispatch context (defaults to 1 if not provided)
    this.syncDepth = dispatchItem.syncDepth ?? 1;

    const callbacks: Array<{
      optionPath: string[];
      args: any[];
      deferredTagRemoval?: { noteId: string; actorId: string };
    }> = [];

    // Handle note items
    if (dispatchItem.itemType === "note") {
      const { item, isCreate = true } = dispatchItem; // Default true for backwards compat

      // Build the current note
      const currentNote = buildNoteFromDbRecord(item);

      // Dispatch intent matching if twist was mentioned in this note and it's a create
      const isMentioned = (currentNote.mentions ?? []).includes(
        this.priorityTwistId
      );
      if (isMentioned && isCreate) {
        const result = await intentOps.handleIntent(this, currentNote);

        if (!result) {
          // Built-in intent handled or no intent matched - notes already created
          // Remove tag immediately
          try {
            const userId = await this.getUserId();
            await rpcUser(this.db, "update_note_tags", {
              user_id: userId,
              p_note_id: currentNote.id,
              p_actor_id: currentNote.author.id,
              p_client_id: 0, // API client
              p_tag_updates: { [Tag.Twist]: false },
            });
          } catch (error) {
            // Log but don't fail - tag removal is best-effort
            logger.warn("Failed to remove Twisting tag from note", {
              note_id: currentNote.id,
              error: error instanceof Error ? error.message : String(error),
            });
          }
        } else {
          // Custom intent - defer tag removal until callback completes
          callbacks.push({
            ...result,
            deferredTagRemoval: {
              noteId: currentNote.id,
              actorId: currentNote.author.id,
            },
          });
        }
      }

      // Dispatch note.created callback for new notes on activities created by this twist
      if (isCreate) {
        // Check if parent activity was created by this twist (from payload metadata)
        const activityCreatedByThisTwist =
          item.activity_created_by === this.priorityTwistId;

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
      const { item, isCreate = false, changes } = dispatchItem;

      // Build the current activity
      const currentActivity = buildActivityFromDbRecord(item);

      // Check if activity was created by this twist
      const createdByThisTwist =
        (item.created_by ?? item.author_id) === this.priorityTwistId;

      if (createdByThisTwist) {
        if (isCreate) {
          // Future: call activity.created callback when added to twister
          // For now, log for debugging
          logger.info("Activity create received (no callback yet)", {
            activity_id: item.id ?? undefined,
            title: item.title?.substring(0, 30) ?? undefined,
            created_by: item.created_by ?? undefined,
          });
        } else {
          // Check if activity.updated callback exists
          const callback = this.plotOptions?.activity?.updated;
          if (typeof callback === "function") {
            callbacks.push({
              optionPath: ["activity", "updated"],
              args: [
                currentActivity,
                changes ?? { tagsAdded: {}, tagsRemoved: {} },
              ],
            });
          }
        }
      }
    }

    return callbacks;
  }

  /**
   * Notifies UserSync and TwistSync DOs for all users and twists with access
   * to the given priorities. Called after twist batch operations since triggers
   * skip HTTP calls for twist-originated writes (negative updated_by).
   *
   * Safe to fail — the recovery system detects stale sync state within 30s.
   */
  async notifySyncDOs(priorityIds: Set<string>): Promise<void> {
    try {
      // 1. Get all users with access to affected priorities
      const userIds = new Set<string>();
      for (const priorityId of priorityIds) {
        // rpc() unwraps single-column TABLE results, so we get string[] (user IDs) directly
        // TypeScript still thinks these are { user_id: string } from generated types, but runtime is string
        const data = await rpc(this.db, "get_users_with_priority_access", {
          target_priority_id: priorityId,
        }) as unknown as string | string[] | null;
        if (data) for (const userId of Array.isArray(data) ? data : [data]) userIds.add(userId);
      }

      // 2. Notify UserSync DOs (they debounce internally)
      for (const userId of userIds) {
        const doId = this.env.USER_SYNC.idFromName(userId);
        const userSync = this.env.USER_SYNC.get(doId);
        const result = await userSync.fetch(
          new Request("http://do/notify", {
            method: "POST",
            body: JSON.stringify({ id: userId }),
          })
        );
        disposeRpc(result);
      }

      // 3. Notify TwistSync DOs for other twists on these priorities
      //    (skip self — same echo prevention as triggers)
      const twists = await this.db
        .selectFrom("priority_twist")
        .select("id")
        .where("priority_id", "in", Array.from(priorityIds))
        .where("archived_at", "is", null)
        .where("id", "!=", this.priorityTwistId)
        .execute();

      for (const twist of twists) {
        const doId = this.env.TWIST_SYNC.idFromName(twist.id);
        const twistSync = this.env.TWIST_SYNC.get(doId);
        const result = await twistSync.fetch(
          new Request("http://do/notify", {
            method: "POST",
            body: JSON.stringify({ id: twist.id }),
          })
        );
        disposeRpc(result);
      }
    } catch (error) {
      // Log but don't fail — recovery system catches stale sync state within 30s
      const logger = createLogger({
        priority_twist_id: this.priorityTwistId,
      });
      logger.error("Failed to notify sync DOs", error as Error);
    }
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
   * Removes the Twisting tag from a note. Used for deferred tag removal after callbacks.
   */
  async removeTagFromNote(noteId: string, actorId: string): Promise<void> {
    const logger = createLogger({ priority_twist_id: this.priorityTwistId });
    try {
      const userId = await this.getUserId();
      await rpcUser(this.db, "update_note_tags", {
        user_id: userId,
        p_note_id: noteId,
        p_actor_id: actorId,
        p_client_id: 0, // API client
        p_tag_updates: { [Tag.Twist]: false },
      });
    } catch (error) {
      // Log but don't fail - tag removal is best-effort
      logger.warn("Failed to remove deferred Twisting tag from note", {
        note_id: noteId,
        error: error instanceof Error ? error.message : String(error),
      });
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
    const data = await this.db
      .selectFrom("priority_child")
      .select("child_id")
      .where("priority_id", "=", this.priorityId)
      .where("child_id", "=", priorityId)
      .executeTakeFirst();

    if (!data) {
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
  async validateNoteCreateAccess(
    activityId: string,
    activityMetadata?: {
      created_by: string | null;
      mentions: string[] | null;
    }
  ): Promise<void> {
    let created_by: string | null;
    let mentions: string[] | null;

    if (activityMetadata) {
      created_by = activityMetadata.created_by;
      mentions = activityMetadata.mentions;
    } else {
      // Fetch the parent activity to check permissions (fallback for calls from twist code)
      try {
        const activity = await this.db
          .selectFrom("activity_x")
          .select(["id", "author_id", "created_by", "mentions"])
          .where("id", "=", activityId)
          .executeTakeFirstOrThrow();

        created_by = activity.created_by;
        mentions = activity.mentions as string[] | null;
      } catch {
        throw new Error(`Activity not found: ${activityId}`);
      }
    }

    // Check if the activity was created by this twist
    if (created_by === this.priorityTwistId) {
      return;
    }

    // Check if the activity mentions the twist
    if (Array.isArray(mentions) && mentions.includes(this.priorityTwistId)) {
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
   * @param activityMetadata - Optional activity metadata from note payload to avoid database query
   */
  async validateActivityUpdateAccess(
    activityId: string,
    activityMetadata?: {
      created_by: string | null;
      mentions: string[] | null;
      triggering_note_mentions?: string[] | null;
    }
  ): Promise<void> {
    let created_by: string | null;
    let mentions: string[] | null;
    let triggering_note_mentions: string[] | null | undefined;

    if (activityMetadata) {
      created_by = activityMetadata.created_by;
      mentions = activityMetadata.mentions;
      triggering_note_mentions = activityMetadata.triggering_note_mentions;
    } else {
      // Fetch the activity to check author and mentions (fallback for calls from twist code)
      try {
        const activity = await this.db
          .selectFrom("activity_x")
          .select(["id", "author_id", "created_by", "mentions"])
          .where("id", "=", activityId)
          .executeTakeFirstOrThrow();

        created_by = activity.created_by;
        mentions = activity.mentions as string[] | null;
      } catch {
        throw new Error(`Activity not found: ${activityId}`);
      }
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
      triggering_note_mentions &&
      Array.isArray(triggering_note_mentions) &&
      triggering_note_mentions.includes(this.priorityTwistId)
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
  ): Promise<Uuid> {
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
    activities: (NewActivity | NewActivityWithNotes)[]
  ): Promise<Uuid[]> {
    return activityOps.createActivities(this, activities);
  }

  // Priority operations
  async createPriority(priority: NewPriority): Promise<Priority & { created: boolean }> {
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
  async addContacts(contacts: NewContact[]): Promise<Actor[]> {
    return contactsOps.addContacts(this, contacts);
  }

  async getActors(ids: ActorId[]): Promise<Actor[]> {
    return contactsOps.getActors(this, ids);
  }

  // Note operations
  async getNotes(activity: Activity): Promise<Note[]> {
    return activityOps.getNotes(this, activity);
  }

  async getNote(note: { id: Uuid } | { key: string }): Promise<Note | null> {
    return activityOps.getNote(this, note);
  }

  async createNote(note: NewNote, skipActivityRead = false): Promise<Uuid> {
    return activityOps.createNote(this, note, skipActivityRead);
  }

  async createNotes(notes: NewNote[]): Promise<Uuid[]> {
    return activityOps.createNotes(this, notes);
  }

  async updateNote(note: NoteUpdate): Promise<void> {
    return activityOps.updateNote(this, note);
  }
}
