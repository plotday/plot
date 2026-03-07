import { sql, type Kysely } from "kysely";

import {
  type Thread,
  type ThreadUpdate,
  type Actor,
  type ActorId,
  ActorType,
  type Link,
  type NewThread,
  type NewThreadWithNotes,
  type NewLinkWithNotes,
  type NewContact,
  type NewNote,
  type NewPriority,
  type Note,
  type NoteUpdate,
  type Priority,
  type PriorityUpdate,
  type Uuid,
} from "@plotday/twister/plot";
import type {
  Schedule,
  NewSchedule,
} from "@plotday/twister/schedule";
import { Tag } from "@plotday/twister/tag";
import {
  ThreadAccess,
  ContactAccess,
  type Plot as IPlot,
  type LinkFilter,
  type SearchResult,
  type SearchOptions,
  PriorityAccess,
} from "@plotday/twister/tools/plot";
import { createLogger } from "@plotday/worker-util";

import type { Json } from "@plotday/db";
import type { DB } from "../../../db-types";
import type { Bindings } from "../../../env";
import { rpc, rpcUser } from "../../../rpc";
import { truncateUuidForUpdatedBy } from "../../../utils/uuid";
import { type PermissionFlag, type ToolPermission } from "../../permissions";
import type {
  EnrichedThread,
  EnrichedNote,
  ChannelLinkCreate,
  ChannelLinkUpdate,
  ChannelNoteCreate,
  ThreadReadChange,
  ThreadScheduleChange,
  ScheduleContactChange,
} from "../../view-types";
import { AI } from "../ai";
import { Tool } from "../tool";
import * as threadOps from "./thread";
import * as linkOps from "./link";
import * as contactsOps from "./contacts";
import { fromDbLink } from "./converters";
import { buildThreadFromDbRecord, buildNoteFromDbRecord } from "./db";
import * as intentOps from "./intent";
import * as searchOps from "./search";
import * as priorityOps from "./priority";
import { convertScheduleToDb, convertDbToSchedule } from "./schedule";
import { processScheduleContacts } from "./schedule-contacts";

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
      itemType: "thread";
      item: EnrichedThread;
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
    }
  | {
      itemType: "channel_link";
      item: ChannelLinkCreate | ChannelLinkUpdate;
      isCreate?: boolean;
      syncDepth?: number;
    }
  | {
      itemType: "channel_note";
      item: ChannelNoteCreate;
      isCreate?: boolean;
      syncDepth?: number;
    }
  | {
      itemType: "thread_read";
      item: ThreadReadChange;
      syncDepth?: number;
    }
  | {
      itemType: "thread_schedule";
      item: ThreadScheduleChange;
      syncDepth?: number;
    }
  | {
      itemType: "schedule_contact";
      item: ScheduleContactChange;
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

    if (options?.thread) {
      // Can create new activities
      if (options.thread.access === ThreadAccess.Create) {
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

    if (options?.link) {
      perms.push({
        domain: "plot",
        entity: "link",
        flags: ["read"],
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

    if (options?.search) {
      perms.push({ domain: "plot", entity: "search", flags: ["read"] });
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
   * Dispatches activity, note, and channel link events to configured callbacks.
   *
   * @param dispatchItem - Discriminated union containing entity data
   * @returns Array of callbacks to invoke in twist worker (empty array if none)
   */
  async dispatch(
    dispatchItem: DispatchItem
  ): Promise<Array<{ sourceMethod?: string; optionPath?: string[]; args: any[] }>> {
    const logger = createLogger({ priority_twist_id: this.priorityTwistId });

    if (!this.plotOptions) {
      return [];
    }

    // Set sync depth from dispatch context (defaults to 1 if not provided)
    this.syncDepth = dispatchItem.syncDepth ?? 1;

    const callbacks: Array<{
      sourceMethod?: string;
      optionPath?: string[];
      args: any[];
      deferredTagRemoval?: { noteId: string; actorId: string };
    }> = [];

    // Handle note items
    if (dispatchItem.itemType === "note") {
      const { item, isCreate = true } = dispatchItem; // Default true for backwards compat

      // Skip notes created by this twist to prevent self-response loops
      if (isCreate && item.created_by === this.priorityTwistId) {
        return [];
      }

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

      // Dispatch onNoteCreated for new notes on threads created by this twist
      if (isCreate) {
        const activityCreatedByThisTwist =
          item.thread_created_by === this.priorityTwistId;
        const noteCreatedByThisTwist = item.created_by === this.priorityTwistId;

        if (activityCreatedByThisTwist && !noteCreatedByThisTwist) {
          if (this.plotOptions?.thread?.access) {
            // Fetch thread with meta populated for the onNoteCreated callback
            const thread = await this.getThread({ id: item.thread_id as Uuid });
            if (thread) {
              const link = await this.db
                .selectFrom("link")
                .select(["meta", "channel_id", "source"])
                .where("thread_id", "=", item.thread_id!)
                .where("created_by", "=", this.priorityTwistId)
                .executeTakeFirst();
              thread.meta = {
                ...(link?.meta as Record<string, unknown> ?? {}),
                channelId: link?.channel_id ?? null,
                linkSource: link?.source ?? null,
              };
              callbacks.push({
                sourceMethod: "onNoteCreated",
                args: [currentNote, thread],
              });
            }
          }
        }
      }
    }

    // Handle thread items
    if (dispatchItem.itemType === "thread") {
      const { item, isCreate = false, changes } = dispatchItem;

      const currentActivity = buildThreadFromDbRecord(item);

      const createdByThisTwist =
        item.created_by === this.priorityTwistId;

      if (createdByThisTwist && !isCreate) {
        if (this.plotOptions?.thread?.access) {
          callbacks.push({
            sourceMethod: "onThreadUpdated",
            args: [
              currentActivity,
              changes ?? { tagsAdded: {}, tagsRemoved: {} },
            ],
          });
        }
      }
    }

    // Handle channel link items (from connected source channels)
    if (dispatchItem.itemType === "channel_link") {
      if (this.plotOptions?.link) {
        const { item, isCreate = true } = dispatchItem;
        const link = this.buildLinkFromChannelView(item);
        const notes = await this.fetchNotesForThread(item.thread_id!);

        if (isCreate) {
          callbacks.push({
            sourceMethod: "onLinkCreated",
            args: [link, notes],
          });
        } else {
          callbacks.push({
            sourceMethod: "onLinkUpdated",
            args: [link, notes],
          });
        }
      }
    }

    // Handle channel note items (notes on threads with links from connected channels)
    if (dispatchItem.itemType === "channel_note") {
      if (this.plotOptions?.link) {
        const { item } = dispatchItem;
        const note = this.buildNoteFromChannelView(item);
        const link = this.buildLinkFromChannelNoteView(item);

        callbacks.push({
          sourceMethod: "onLinkNoteCreated",
          args: [note, link],
        });
      }
    }

    // Handle thread read status changes (for onThreadRead callback)
    if (dispatchItem.itemType === "thread_read") {
      const { item } = dispatchItem;
      if (this.plotOptions?.thread?.access) {
        const thread = await this.getThread({ id: item.thread_id as Uuid });
        if (thread) {
          const actors = await contactsOps.getActors(this, [item.user_id as ActorId]);
          if (actors.length > 0) {
            // Populate thread.meta from link row
            const link = await this.db
              .selectFrom("link")
              .select(["meta", "channel_id", "source"])
              .where("thread_id", "=", item.thread_id!)
              .where("created_by", "=", this.priorityTwistId)
              .executeTakeFirst();
            thread.meta = {
              ...(link?.meta as Record<string, unknown> ?? {}),
              channelId: link?.channel_id ?? null,
              linkSource: link?.source ?? null,
            };
            callbacks.push({
              sourceMethod: "onThreadRead",
              args: [thread, actors[0], !item.read_at],
            });
          }
        }
      }
    }

    // Handle thread schedule changes (for onThreadToDo callback)
    if (dispatchItem.itemType === "thread_schedule") {
      const { item } = dispatchItem;
      if (this.plotOptions?.thread?.access) {
        const thread = await this.getThread({ id: item.thread_id as Uuid });
        if (thread) {
          const actors = await contactsOps.getActors(this, [item.user_id as ActorId]);
          if (actors.length > 0) {
            // Populate thread.meta from link row
            const link = await this.db
              .selectFrom("link")
              .select(["meta", "channel_id", "source"])
              .where("thread_id", "=", item.thread_id!)
              .where("created_by", "=", this.priorityTwistId)
              .executeTakeFirst();
            thread.meta = {
              ...(link?.meta as Record<string, unknown> ?? {}),
              channelId: link?.channel_id ?? null,
              linkSource: link?.source ?? null,
            };

            // todo=true if schedule is active (on/at set, not done); false otherwise
            const todo = (item.on != null || item.at != null) && item.done_at == null;

            // Extract date from schedule's on (daterange) or at (tstzrange)
            let date: Date | undefined;
            if (item.on != null) {
              // daterange format: [start,end) — extract start date
              const match = String(item.on).match(/[\[(](\d{4}-\d{2}-\d{2})/);
              if (match) date = new Date(match[1]);
            } else if (item.at != null) {
              // tstzrange format: ["start","end") — extract start timestamp
              const match = String(item.at).match(/[\[("]([\d\-T:.+Z]+)/);
              if (match) date = new Date(match[1]);
            }

            callbacks.push({
              sourceMethod: "onThreadToDo",
              args: [thread, actors[0], todo, { date }],
            });
          }
        }
      }
    }

    // Handle schedule contact changes (for onScheduleContactUpdated callback)
    // Only fires for non-archived contacts (status changes).
    // Future: archived_at changes can drive onScheduleContactRemoved/onScheduleContactAdded callbacks.
    if (dispatchItem.itemType === "schedule_contact") {
      const { item } = dispatchItem;
      if (this.plotOptions?.thread?.access && !item.archived_at) {
        const thread = await this.getThread({ id: item.thread_id as Uuid });
        if (thread) {
          const actors = await contactsOps.getActors(this, [item.contact_id as ActorId]);
          if (actors.length > 0) {
            // Populate thread.meta from link row
            const link = await this.db
              .selectFrom("link")
              .select(["meta", "channel_id", "source"])
              .where("thread_id", "=", item.thread_id!)
              .where("created_by", "=", this.priorityTwistId)
              .executeTakeFirst();
            thread.meta = {
              ...(link?.meta as Record<string, unknown> ?? {}),
              channelId: link?.channel_id ?? null,
              linkSource: link?.source ?? null,
            };
            callbacks.push({
              sourceMethod: "onScheduleContactUpdated",
              args: [thread, item.schedule_id, item.contact_id as ActorId, item.status ?? null, actors[0]],
            });
          }
        }
      }
    }

    return callbacks;
  }

  /**
   * Converts a channel link view row into an SDK Link object.
   */
  private buildLinkFromChannelView(item: ChannelLinkCreate | ChannelLinkUpdate): Link {
    return fromDbLink({
      id: item.id!,
      thread_id: item.thread_id!,
      source: item.source,
      source_created_at: item.source_created_at ?? item.created_at!,
      created_at: item.created_at!,
      title: item.title,
      preview: item.preview,
      type: item.type,
      status: item.status,
      actions: item.actions,
      meta: item.meta,
      source_url: item.source_url,
      channel_id: item.channel_id,
      author_id: item.author_id,
      assignee_id: item.assignee_id,
      author: item.author_id ? {
        id: item.author_id,
        name: item.author_name,
        type: item.author_type,
      } : null,
    });
  }

  /**
   * Converts a channel note view row into an SDK Note object.
   */
  private buildNoteFromChannelView(item: ChannelNoteCreate): Note {
    return {
      id: item.id as Uuid,
      created: item.created_at ? new Date(item.created_at) : new Date(),
      // @ts-ignore - Partial Thread data
      thread: {
        id: item.thread_id,
        title: item.thread_title,
        priority: { id: item.priority_id },
      } as unknown as Thread,
      author: {
        id: (item.author_id ?? item.created_by) as ActorId,
        name: item.author_name,
        type:
          item.author_type === "user"
            ? ActorType.User
            : item.author_type === "priority_twist"
            ? ActorType.Twist
            : ActorType.Contact,
      },
      content: item.content,
      key: item.key || null,
      reNote: item.re_note_id ? { id: item.re_note_id as Uuid } : null,
      mentions: (item.mentions as ActorId[]) || [],
      tags: (item.tags as Partial<Record<number, ActorId[]>>) || {},
      private: item.private ?? false,
      archived: item.archived_at !== null,
      actions: item.actions as any,
    };
  }

  /**
   * Builds a minimal Link from channel note view link_ fields.
   */
  private buildLinkFromChannelNoteView(item: ChannelNoteCreate): Link {
    return {
      id: item.link_id as Uuid,
      threadId: item.thread_id as Uuid,
      source: item.link_source,
      created: new Date(),
      author: null,
      title: item.link_title || "",
      preview: null,
      assignee: null,
      type: item.link_type,
      status: null,
      actions: null,
      meta: item.link_meta as any,
      sourceUrl: item.link_source_url,
      channelId: item.link_channel_id ?? null,
    };
  }

  /**
   * Fetches notes for a thread (for link callbacks that include notes).
   */
  private async fetchNotesForThread(threadId: string): Promise<Note[]> {
    try {
      const rows = await this.db
        .selectFrom("note")
        .leftJoin("actor", "actor.id", "note.author_id")
        .select([
          "note.id",
          "note.created_at",
          "note.thread_id",
          "note.author_id",
          "note.created_by",
          "note.content",
          "note.key",
          "note.re_note_id",
          "note.mentions",
          "note.private",
          "note.archived_at",
          "note.actions",
          "actor.name as author_name",
          "actor.type as author_type",
        ])
        .where("note.thread_id", "=", threadId)
        .where("note.draft", "=", false)
        .where("note.archived_at", "is", null)
        .orderBy("note.created_at", "asc")
        .execute();

      return rows.map((row) => ({
        id: row.id as Uuid,
        created: row.created_at ? new Date(row.created_at) : new Date(),
        // @ts-ignore - Partial Thread data
        thread: { id: row.thread_id } as unknown as Thread,
        author: {
          id: (row.author_id ?? row.created_by) as ActorId,
          name: row.author_name ?? null,
          type:
            row.author_type === "user"
              ? ActorType.User
              : row.author_type === "priority_twist"
              ? ActorType.Twist
              : ActorType.Contact,
        },
        content: row.content,
        key: row.key || null,
        reNote: row.re_note_id ? { id: row.re_note_id as Uuid } : null,
        mentions: (row.mentions as ActorId[]) || [],
        tags: {},
        private: row.private ?? false,
        archived: row.archived_at !== null,
        actions: row.actions as any,
      }));
    } catch {
      return [];
    }
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
        await userSync.fetch(
          new Request("http://do/notify", {
            method: "POST",
            body: JSON.stringify({ id: userId }),
          })
        );
      }

      // 3. Notify TwistSync DOs for other twists on ancestor priorities
      //    (twists installed on ancestors have access to descendant priorities)
      //    (skip self — same echo prevention as triggers)
      const priorityIdArray = Array.from(priorityIds);
      const twists = await this.db
        .selectFrom("priority_twist")
        .innerJoin("priority as twist_priority", "twist_priority.id", "priority_twist.priority_id")
        .innerJoin("priority as changed_priority", (join) =>
          join.on("changed_priority.id", "in", priorityIdArray)
        )
        .select("priority_twist.id")
        .where("priority_twist.archived_at", "is", null)
        .where("priority_twist.id", "!=", this.priorityTwistId)
        .where(sql<boolean>`${sql.ref("changed_priority.path")} <@ ${sql.ref("twist_priority.path")}`)
        .groupBy("priority_twist.id")
        .execute();

      for (const twist of twists) {
        const doId = this.env.TWIST_SYNC.idFromName(twist.id);
        const twistSync = this.env.TWIST_SYNC.get(doId);
        await twistSync.fetch(
          new Request("http://do/notify", {
            method: "POST",
            body: JSON.stringify({ id: twist.id }),
          })
        );
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
  requireThreadAccess(required: ThreadAccess): void {
    const granted = this.plotOptions?.thread?.access;
    if (granted === undefined) {
      throw new Error(
        `Activity access not requested. Required: ${ThreadAccess[required]}`
      );
    }

    // Check if granted permission is sufficient
    // Create includes Respond permissions
    if (
      required === ThreadAccess.Respond &&
      granted >= ThreadAccess.Respond
    ) {
      return;
    }
    if (
      required === ThreadAccess.Create &&
      granted >= ThreadAccess.Create
    ) {
      return;
    }

    throw new Error(
      `Insufficient activity access. Required: ${ThreadAccess[required]}, Granted: ${ThreadAccess[granted]}`
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
  async validateActivityCreateAccess(_activity: NewThread): Promise<void> {
    this.requireThreadAccess(ThreadAccess.Create);
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
          .selectFrom("thread_x")
          .select(["id", "created_by", "mentions"])
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
      this.requireThreadAccess(ThreadAccess.Respond);
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
          .selectFrom("thread_x")
          .select(["id", "created_by", "mentions"])
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
      this.requireThreadAccess(ThreadAccess.Create);
      return;
    }

    // Check if activity mentions the twist
    if (
      mentions &&
      Array.isArray(mentions) &&
      mentions.includes(this.priorityTwistId)
    ) {
      this.requireThreadAccess(ThreadAccess.Respond);
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
      this.requireThreadAccess(ThreadAccess.Respond);
      return;
    }

    // Fallback: Check if activity was created by another instance of the same twist
    // This allows twists to update activities created by any instance of the same twist,
    // which is useful when activities are moved between priorities or when multiple
    // instances of the same twist are installed in different priorities
    if (created_by && (await this.isSameTwistDefinition(created_by))) {
      this.requireThreadAccess(ThreadAccess.Create);
      // Skip priority validation - twist can access activities it created regardless of priority
      return;
    }

    throw new Error(
      `Cannot update activity: twist was not mentioned and did not create the activity`
    );
  }

  // Thread operations
  async createThread(
    thread: NewThread | NewThreadWithNotes
  ): Promise<Uuid> {
    return threadOps.createThread(this, thread);
  }

  // Link operations
  async createLink(
    link: NewLinkWithNotes
  ): Promise<Uuid> {
    return linkOps.createLink(this, link);
  }

  async createLinkOnly(
    link: NewLinkWithNotes
  ): Promise<Uuid> {
    return linkOps.createLinkOnly(this, link);
  }

  async updateThread(thread: ThreadUpdate): Promise<void> {
    return threadOps.updateThread(this, thread);
  }

  async getThread(
    thread: { id: Uuid } | { source: string }
  ): Promise<Thread | null> {
    return threadOps.getThread(this, thread);
  }

  async createThreads(
    threads: (NewThread | NewThreadWithNotes)[]
  ): Promise<Uuid[]> {
    return threadOps.createThreads(this, threads);
  }

  /** @deprecated Use createThread */
  async createActivity(
    activity: NewThread | NewThreadWithNotes
  ): Promise<Uuid> {
    return this.createThread(activity);
  }

  /** @deprecated Use updateThread */
  async updateActivity(activity: ThreadUpdate): Promise<void> {
    return this.updateThread(activity);
  }

  /** @deprecated Use getThread */
  async getActivity(
    activity: { id: Uuid } | { source: string }
  ): Promise<Thread | null> {
    return this.getThread(activity);
  }

  /** @deprecated Use createThreads */
  async createActivities(
    activities: (NewThread | NewThreadWithNotes)[]
  ): Promise<Uuid[]> {
    return this.createThreads(activities);
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
  async getNotes(activity: Thread): Promise<Note[]> {
    return threadOps.getNotes(this, activity);
  }

  async getNote(note: { id: Uuid } | { key: string }): Promise<Note | null> {
    return threadOps.getNote(this, note);
  }

  async createNote(note: NewNote, skipActivityRead = false): Promise<Uuid> {
    return threadOps.createNote(this, note, skipActivityRead);
  }

  async createNotes(notes: NewNote[]): Promise<Uuid[]> {
    return threadOps.createNotes(this, notes);
  }

  async updateNote(note: NoteUpdate): Promise<void> {
    return threadOps.updateNote(this, note);
  }

  // Schedule operations
  async createSchedule(schedule: NewSchedule): Promise<Schedule> {
    const dbSchedule = convertScheduleToDb(schedule, {
      thread_id: schedule.threadId,
    });
    const userId = await this.getUserId();
    const result = await rpcUser(this.db, "upsert_schedule", {
      user_id: userId,
      p_schedule: dbSchedule as Json,
    });

    // Process contacts if present
    if (schedule.contacts?.length && result?.id) {
      const thread = await this.db
        .selectFrom("thread")
        .select("priority_id")
        .where("id", "=", schedule.threadId)
        .executeTakeFirstOrThrow();

      await processScheduleContacts(
        this,
        result.id,
        schedule.contacts,
        thread.priority_id
      );
    }

    return convertDbToSchedule(result as Record<string, unknown>);
  }


  async getSchedules(_threadId: Uuid): Promise<Schedule[]> {
    throw new Error("Schedule operations not yet implemented");
  }

  async getLinks(_filter?: LinkFilter): Promise<Array<{ link: Link; notes: Note[] }>> {
    return linkOps.getLinks(this, _filter);
  }

  async search(query: string, options?: SearchOptions): Promise<SearchResult[]> {
    return searchOps.search(this, query, options);
  }
}
