import { sql, type Kysely } from "kysely";
import { PostHog } from "posthog-node";

import { Tag } from "@plotday/twister/tag";

import {
  type Action,
  type Thread,
  type ThreadUpdate,
  type Actor,
  type ActorId,
  ActorType,
  type Link,
  type LinkUpdate,
  type NewThread,
  type NewThreadWithNotes,
  type NewLinkWithNotes,
  type NewContact,
  type NewNote,
  type NewPriority,
  type Note,
  type NoteUpdate,
  type PlanOperation,
  type Priority,
  type PriorityUpdate,
  type Uuid,
  ActionType,
} from "@plotday/twister/plot";
import type {
  Schedule,
  NewSchedule,
} from "@plotday/twister/schedule";
import type { Callback } from "@plotday/twister/tools/callbacks";
import {
  ThreadAccess,
  ContactAccess,
  LinkAccess,
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
 * Key format: `${twistInstanceId}` (the twist_instance.id)
 * Value: `twist_id` from twist_instance table
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
  public twistInstanceId: ActorId;
  public plotOptions?: typeof IPlot.Options;
  public env: Bindings;
  public ai: AI;
  public syncDepth: number = 1;
  private _actor?: Actor;
  private _owner?: Actor;
  private _twistId?: number;
  private _userId?: string;
  private _rootPriorityId?: string;
  private _priorityRoot?: string;
  private _aiEnabled?: boolean;

  /**
   * Returns permissions required by this Plot tool instance.
   * @param options - Plot tool options
   * @returns Array of ToolPermissions based on configured access levels
   */
  static Permissions(options?: PlotOptions): ToolPermission[] {
    const perms: ToolPermission[] = [];

    if (options?.thread) {
      if (options.thread.access === ThreadAccess.Full) {
        // Full: read, write, update any activity in scope
        perms.push({
          domain: "plot",
          entity: "activity:any",
          flags: ["read", "write", "update"],
        });
      } else if (options.thread.access === ThreadAccess.Create) {
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
      const linkOption = options.link;
      if (typeof linkOption === "object" && linkOption.access !== undefined) {
        let flags: PermissionFlag[] = ["read"];
        if (linkOption.access === LinkAccess.Full) {
          flags = ["read", "write", "update"];
        }
        perms.push({
          domain: "plot",
          entity: "link",
          flags,
        });
      } else {
        // link: true — source channel processing only
        perms.push({
          domain: "plot",
          entity: "link",
          flags: ["read"],
        });
      }
    }

    if (options?.requireApproval) {
      perms.push({
        domain: "plot",
        entity: "plan",
        flags: ["write"],
      });
    }

    if (options?.contact?.access !== undefined) {
      perms.push({
        domain: "plot",
        entity: "contact",
        flags: ["read"],
      });
    }

    if (options?.search) {
      perms.push({ domain: "plot", entity: "search", flags: ["read"] });
    }

    return perms;
  }

  constructor({
    db,
    twistInstanceId,
    options,
    env,
  }: {
    db: Kysely<DB>;
    twistInstanceId: string;
    options?: typeof IPlot.Options;
    env: Bindings;
  }) {
    super();
    this.db = db;
    this.twistInstanceId = twistInstanceId as ActorId;
    this.plotOptions = options;
    this.env = env;
    this.ai = new AI({ env, twistInstanceId });
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
          .where("id", "=", this.twistInstanceId)
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
   * Gets the user ID who owns this twist (from twist_instance.owner_id).
   * Fetches and caches it on first access.
   * @returns The user ID
   * @throws Error if the owner_id cannot be fetched
   */
  async getUserId(): Promise<string> {
    if (!this._userId) {
      try {
        const data = await this.db
          .selectFrom("twist_instance")
          .select("owner_id")
          .where("id", "=", this.twistInstanceId)
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
   * Gets the primary contact Actor for the twist owner, fetching and caching on first access.
   * Email is only included if the twist has ContactAccess.Read permission.
   * @returns The owner's Actor (contact ID, name, and optionally email)
   */
  async getOwner(): Promise<Actor> {
    if (!this._owner) {
      const userId = await this.getUserId();
      const hasContactRead =
        this.plotOptions?.contact?.access !== undefined &&
        this.plotOptions.contact.access >= ContactAccess.Read;
      const row = await this.db
        .selectFrom("contact")
        .select(hasContactRead ? ["id", "name", "email"] : ["id", "name"])
        .where("user_id", "=", userId)
        .where("primary", "=", true)
        .executeTakeFirstOrThrow();
      const email = hasContactRead
        ? (row as { id: string; name: string | null; email: string | null }).email
        : null;
      this._owner = {
        id: row.id as ActorId,
        type: ActorType.Contact,
        name: row.name ?? null,
        ...(email ? { email } : {}),
      };
    }
    return this._owner!;
  }

  /**
   * Checks whether AI features are enabled for the owner of this priority.
   * Queries user_settings.ai_enabled and caches the result for the request.
   * @returns true if AI is enabled (default), false if explicitly disabled
   */
  async isAiEnabled(): Promise<boolean> {
    if (this._aiEnabled !== undefined) return this._aiEnabled;

    try {
      const userId = await this.getUserId();

      const settings = await this.db
        .selectFrom("user_settings")
        .select("ai_enabled")
        .where("user_id", "=", userId)
        .executeTakeFirst();

      // null or true = enabled, only explicit false disables
      this._aiEnabled = settings?.ai_enabled !== false;
    } catch {
      // Default to enabled if we can't determine the setting
      this._aiEnabled = true;
    }

    return this._aiEnabled;
  }

  /**
   * Returns the owner user's root priority ID (oldest nlevel=1 priority).
   * Used as a structural default when no explicit parent is supplied
   * (e.g. priority.create() without a parent, link source fallback).
   */
  async getRootPriorityId(userId?: string): Promise<string> {
    if (!this._rootPriorityId) {
      const uid = userId ?? (await this.getUserId());
      const row = await this.db
        .selectFrom("priority")
        .select("id")
        .where("user_id", "=", uid)
        .where("archived_at", "is", null)
        .orderBy(sql`nlevel(path)`, "asc")
        .orderBy("created_at", "asc")
        .limit(1)
        .executeTakeFirstOrThrow();
      this._rootPriorityId = row.id;
    }
    return this._rootPriorityId;
  }

  /**
   * Returns the team_id (as a string, matching the Int8 select type) for a
   * twist_instance actor, or null if it is a personal (non-team) twist instance.
   */
  async getTwistInstanceTeamId(actorId: string): Promise<string | null> {
    const row = await this.db
      .selectFrom("twist_instance")
      .select("team_id")
      .where("id", "=", actorId)
      .executeTakeFirst();
    // Int8 columns are returned as strings at runtime.
    return (row?.team_id as string | null) ?? null;
  }

  /**
   * Returns the ID of the user's first (shallowest, oldest) priority that
   * belongs to the given team, or null if the user has no team priorities.
   * @param teamId - The team_id as a string (Int8 select type).
   */
  async getFirstTeamPriorityId(userId: string, teamId: string): Promise<string | null> {
    const row = await this.db
      .selectFrom("priority")
      // @ts-ignore - Kysely infers Int8 filter as number, but string is correct at runtime
      .where("team_id", "=", teamId)
      .select("id")
      .where("user_id", "=", userId)
      .where("archived_at", "is", null)
      .orderBy(sql`nlevel(path)`, "asc")
      .orderBy("created_at", "asc")
      .limit(1)
      .executeTakeFirst();
    return row?.id ?? null;
  }

  /**
   * Gets the root path component of the owner user's default priority.
   * Used for scoping key lookups to the correct priority tree.
   */
  async getPriorityRoot(): Promise<string> {
    if (!this._priorityRoot) {
      try {
        const defaultPriorityId = await this.getRootPriorityId();
        const data = await this.db
          .selectFrom("priority")
          .select("path")
          .where("id", "=", defaultPriorityId)
          .executeTakeFirstOrThrow();

        if (!data.path) {
          throw new Error("No path found");
        }

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
   * Gets the twist definition ID for a given twist_instance ID.
   * Uses worker-level cache to avoid repeated database queries.
   * @param twistInstanceId - The twist_instance.id to look up
   * @returns The twist_id (twist definition ID) or null if not found
   */
  async getTwistId(twistInstanceId: string): Promise<number | null> {
    // Check worker-level cache first
    const cached = TWIST_ID_CACHE.get(twistInstanceId);
    if (cached && Date.now() - cached.timestamp < TWIST_ID_CACHE_TTL_MS) {
      return cached.twist_id;
    }

    // Query database
    const data = await this.db
      .selectFrom("twist_instance")
      .select("twist_id")
      .where("id", "=", twistInstanceId)
      .executeTakeFirst();

    if (!data) {
      return null;
    }

    const twistId = Number(data.twist_id);

    // Cache the result
    TWIST_ID_CACHE.set(twistInstanceId, {
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
   * Checks if the given twist_instance ID belongs to the same twist definition
   * as the current twist instance.
   * @param twistInstanceId - The twist_instance.id to check
   * @returns True if both belong to the same twist definition, false otherwise
   */
  async isSameTwistDefinition(twistInstanceId: string): Promise<boolean> {
    // Get the current twist's definition ID
    if (!this._twistId) {
      const twistId = await this.getTwistId(this.twistInstanceId);
      if (!twistId) {
        return false;
      }
      this._twistId = twistId;
    }

    // Get the other twist's definition ID
    const otherTwistId = await this.getTwistId(twistInstanceId);
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
    const logger = createLogger({ twist_instance_id: this.twistInstanceId });

    if (!this.plotOptions) {
      return [];
    }

    // Set sync depth from dispatch context (defaults to 1 if not provided)
    this.syncDepth = dispatchItem.syncDepth ?? 1;

    // Twisting tag removal is the queue handler's responsibility (see
    // workers/api/src/queue/updates.ts `cleanupAllTwistingTags`). This dispatch
    // just returns callback descriptors; the queue's batch-level `finally`
    // guarantees the tag is cleared regardless of outcome.
    const callbacks: Array<{
      sourceMethod?: string;
      optionPath?: string[];
      args: any[];
    }> = [];

    // Handle note items
    if (dispatchItem.itemType === "note") {
      const { item, isCreate = true } = dispatchItem; // Default true for backwards compat

      // Skip notes created by this twist to prevent self-response loops
      if (isCreate && item.created_by === this.twistInstanceId) {
        return [];
      }

      // Build the current note
      const currentNote = buildNoteFromDbRecord(item);

      // Dispatch intent matching if twist was mentioned in this note and it's a create
      const isMentioned = (currentNote.mentions ?? []).includes(
        this.twistInstanceId
      );
      if (isMentioned && isCreate) {
        try {
          const result = await intentOps.handleIntent(this, currentNote);

          if (result) {
            // Custom intent handler — run in the twist worker.
            callbacks.push(result);
          }
          // Built-in intents and no-match cases are handled inline by
          // handleIntent; nothing more to dispatch.
        } catch (error) {
          // Intent handling failed — log, report, and reply with an error
          // note. Tag cleanup happens in the queue handler's finally.
          logger.error("Intent handling failed for note", error as Error, {
            note_id: currentNote.id,
          });
          const postHog = new PostHog(this.env.POSTHOG_API_KEY, { host: this.env.POSTHOG_HOST, flushAt: 1, flushInterval: 0 });
          const intentUserId = await this.getUserId().catch(() => undefined);
          postHog.captureException(error as Error, intentUserId, { context: "plot:intentHandling", note_id: currentNote.id, twist_instance_id: this.twistInstanceId });
          await postHog.shutdown();
          try {
            await threadOps.createNote(this, {
              thread: { id: currentNote.thread.id },
              content: "Sorry, I ran into an issue processing your request. Please try again later.",
            });
          } catch (replyError) {
            logger.warn("Failed to create error reply note", {
              note_id: currentNote.id,
              error: replyError instanceof Error ? replyError.message : String(replyError),
            });
          }
        }
      }

      // Dispatch onNoteCreated for new notes on threads created by this twist
      if (isCreate) {
        const activityCreatedByThisTwist =
          item.thread_created_by === this.twistInstanceId;
        const noteCreatedByThisTwist = item.created_by === this.twistInstanceId;

        if (activityCreatedByThisTwist && !noteCreatedByThisTwist) {
          if (this.plotOptions?.thread?.access) {
            // Fetch thread with meta populated for the onNoteCreated callback
            const thread = await this.getThread({ id: item.thread_id as Uuid });
            if (thread) {
              const link = await this.db
                .selectFrom("link")
                .select(["meta", "channel_id", "source"])
                .where("thread_id", "=", item.thread_id!)
                .where("created_by", "=", this.twistInstanceId)
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

      const currentActivity = await buildThreadFromDbRecord(this, item);

      const createdByThisTwist =
        item.created_by === this.twistInstanceId;

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
          let actor: Actor;
          if (this.plotOptions?.contact?.access !== undefined && this.plotOptions.contact.access >= ContactAccess.Read) {
            const actors = await contactsOps.getActors(this, [item.user_id as ActorId]);
            actor = actors[0];
          } else {
            actor = { id: item.user_id as ActorId, type: ActorType.Contact, name: null };
          }
          if (actor) {
            // Populate thread.meta from link row
            const link = await this.db
              .selectFrom("link")
              .select(["meta", "channel_id", "source"])
              .where("thread_id", "=", item.thread_id!)
              .where("created_by", "=", this.twistInstanceId)
              .executeTakeFirst();
            thread.meta = {
              ...(link?.meta as Record<string, unknown> ?? {}),
              channelId: link?.channel_id ?? null,
              linkSource: link?.source ?? null,
            };
            callbacks.push({
              sourceMethod: "onThreadRead",
              args: [thread, actor, !item.read_at],
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
          let actor: Actor;
          if (this.plotOptions?.contact?.access !== undefined && this.plotOptions.contact.access >= ContactAccess.Read) {
            const actors = await contactsOps.getActors(this, [item.user_id as ActorId]);
            actor = actors[0];
          } else {
            actor = { id: item.user_id as ActorId, type: ActorType.Contact, name: null };
          }
          if (actor) {
            // Populate thread.meta from link row
            const link = await this.db
              .selectFrom("link")
              .select(["meta", "channel_id", "source"])
              .where("thread_id", "=", item.thread_id!)
              .where("created_by", "=", this.twistInstanceId)
              .executeTakeFirst();
            thread.meta = {
              ...(link?.meta as Record<string, unknown> ?? {}),
              channelId: link?.channel_id ?? null,
              linkSource: link?.source ?? null,
            };

            // todo=true if the per-user thread_state has a date/time intent
            // and the thread hasn't been marked read. The view emits a row
            // any time those fields change, so sources learn when items
            // leave the agenda (read_at gets set or on/at gets cleared).
            const todo =
              item.read_at == null &&
              (item.on != null || item.at != null);

            // Extract date from schedule's on (daterange) or at (tstzrange).
            // Only meaningful when todo=true; omit otherwise.
            let date: Date | undefined;
            if (todo) {
              if (item.on != null) {
                // daterange format: [start,end) — extract start date
                const match = String(item.on).match(/[[(](\d{4}-\d{2}-\d{2})/);
                if (match) date = new Date(match[1]);
              } else if (item.at != null) {
                // tstzrange format: ["start","end") — extract start timestamp
                const match = String(item.at).match(/[[("]([\d\-T:.+Z]+)/);
                if (match) date = new Date(match[1]);
              }
            }

            callbacks.push({
              sourceMethod: "onThreadToDo",
              args: [thread, actor, todo, { date }],
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
        // Link schedules have schedule.thread_id = NULL; resolve via link.
        let link = item.link_id
          ? await this.db
              .selectFrom("link")
              .select(["thread_id", "meta", "channel_id", "source"])
              .where("id", "=", item.link_id)
              .where("created_by", "=", this.twistInstanceId)
              .executeTakeFirst()
          : undefined;
        const threadId = (item.thread_id ?? link?.thread_id ?? null) as Uuid | null;
        if (threadId) {
          const thread = await this.getThread({ id: threadId });
          if (thread) {
            let actor: Actor;
            if (this.plotOptions?.contact?.access !== undefined && this.plotOptions.contact.access >= ContactAccess.Read) {
              const actors = await contactsOps.getActors(this, [item.contact_id as ActorId]);
              actor = actors[0];
            } else {
              actor = { id: item.contact_id as ActorId, type: ActorType.Contact, name: null };
            }
            if (actor) {
              if (!link) {
                link = await this.db
                  .selectFrom("link")
                  .select(["thread_id", "meta", "channel_id", "source"])
                  .where("thread_id", "=", threadId)
                  .where("created_by", "=", this.twistInstanceId)
                  .executeTakeFirst();
              }
              thread.meta = {
                ...(link?.meta as Record<string, unknown> ?? {}),
                channelId: link?.channel_id ?? null,
                linkSource: link?.source ?? null,
              };
              callbacks.push({
                sourceMethod: "onScheduleContactUpdated",
                args: [thread, item.schedule_id, item.contact_id as ActorId, item.status ?? null, actor],
              });
            }
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
            : item.author_type === "twist_instance"
            ? ActorType.Twist
            : ActorType.Contact,
      },
      content: item.content,
      key: item.key || null,
      reNote: item.re_note_id ? { id: item.re_note_id as Uuid } : null,
      mentions: (item.mentions as ActorId[]) || [],
      tags: (item.tags as Partial<Record<number, ActorId[]>>) || {},
      accessContacts: (item.access_contacts as ActorId[]) ?? null,
      archived: item.archived_at !== null,
      actions: item.actions as any,
    };
  }

  /**
   * Builds a minimal Link from channel note view link_ fields.
   */
  private buildLinkFromChannelNoteView(item: ChannelNoteCreate): Link {
    return {
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
      relatedSource: null,
      sources: item.link_source ? [item.link_source] : [],
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
          "note.access_contacts",
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
              : row.author_type === "twist_instance"
              ? ActorType.Twist
              : ActorType.Contact,
        },
        content: row.content,
        key: row.key || null,
        reNote: row.re_note_id ? { id: row.re_note_id as Uuid } : null,
        mentions: (row.mentions as ActorId[]) || [],
        tags: {},
        accessContacts: (row.access_contacts as ActorId[]) ?? null,
        archived: row.archived_at !== null,
        actions: row.actions as any,
      }));
    } catch {
      return [];
    }
  }

  /**
   * Notifies UserSync DOs for all users with access to the given priorities.
   * Called after twist batch operations since triggers skip HTTP calls for
   * twist-originated writes (negative updated_by).
   *
   * Twists are workspace-level: only the priority owner ever sees twist
   * mutations, so there is no fan-out to other twists on the same subtree.
   *
   * Safe to fail — the recovery system detects stale sync state within 30s.
   */
  async notifySyncDOs(priorityIds: Set<string>): Promise<void> {
    try {
      // 1. Get all users with access to affected priorities
      const userIds = new Set<string>();
      for (const priorityId of priorityIds) {
        // rpc() unwraps single-column TABLE results, so we get string[] (user IDs) directly
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
    } catch (error) {
      // Log but don't fail — recovery system catches stale sync state within 30s
      const logger = createLogger({
        twist_instance_id: this.twistInstanceId,
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
      return truncateUuidForUpdatedBy(this.twistInstanceId);
    } catch (error) {
      const logger = createLogger({ twist_instance_id: this.twistInstanceId });
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
    const logger = createLogger({ twist_instance_id: this.twistInstanceId });
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
   * Validates that the given priority belongs to the twist owner. Twists
   * are workspace-level, so they can touch any priority owned by their
   * user (and only those priorities).
   */
  async validatePriorityAccess(priorityId: string): Promise<void> {
    const userId = await this.getUserId();
    const data = await this.db
      .selectFrom("priority")
      .select("id")
      .where("id", "=", priorityId)
      .where("user_id", "=", userId)
      .executeTakeFirst();

    if (!data) {
      throw new Error(
        `Access denied: Priority ${priorityId} does not belong to twist owner ${userId}`
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

    // Higher levels include all lower permissions: Full > Create > Respond
    if (granted >= required) {
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

    if (required === ContactAccess.Read && granted >= ContactAccess.Read) {
      return;
    }

    throw new Error(
      `Insufficient contact access. Required: ${ContactAccess[required]}, Granted: ${ContactAccess[granted]}`
    );
  }

  /**
   * Checks if the twist has the required link access permission.
   * @throws Error if permission is not granted
   */
  requireLinkAccess(required: LinkAccess): void {
    const linkOption = this.plotOptions?.link;
    // link: true only enables source channel processing, not LinkAccess levels
    const granted = typeof linkOption === "object" ? linkOption?.access : undefined;

    if (granted === undefined) {
      throw new Error(
        `Link access not requested. Required: ${LinkAccess[required]}`
      );
    }

    // Higher levels include all lower permissions: Full > Read
    if (granted >= required) {
      return;
    }

    throw new Error(
      `Insufficient link access. Required: ${LinkAccess[required]}, Granted: ${LinkAccess[granted]}`
    );
  }

  /**
   * Checks if requireApproval mode is active.
   * When true, admin operations on content not created by this twist
   * must go through createPlan() instead of being called directly.
   */
  get isApprovalRequired(): boolean {
    return this.plotOptions?.requireApproval === true;
  }

  /**
   * Throws if requireApproval is active and the operation targets content
   * not created by this twist. Call this before admin write operations.
   * @param createdBy - The creator of the target entity (null if unknown)
   */
  enforceApprovalGate(createdBy: string | null): void {
    if (!this.isApprovalRequired) return;
    if (createdBy === this.twistInstanceId) return;
    throw new Error(
      "This twist requires user approval for admin operations. Use createPlan() to submit a plan for approval."
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
          .selectFrom("thread")
          .select(["id", "created_by"])
          .where("id", "=", activityId)
          .executeTakeFirstOrThrow();

        created_by = activity.created_by;
        // Thread no longer stores mentions; note-level mentions are used for twist callbacks
        mentions = null;
      } catch {
        throw new Error(`Activity not found: ${activityId}`);
      }
    }

    // Check if the activity was created by this twist
    if (created_by === this.twistInstanceId) {
      return;
    }

    // Check if the activity mentions the twist
    if (Array.isArray(mentions) && mentions.includes(this.twistInstanceId)) {
      // Twist was mentioned in the activity - requires Respond
      this.requireThreadAccess(ThreadAccess.Respond);
      return;
    }

    // Full access allows creating notes on any thread in scope
    if (
      this.plotOptions?.thread?.access !== undefined &&
      this.plotOptions.thread.access >= ThreadAccess.Full
    ) {
      this.enforceApprovalGate(created_by);
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
      // Fetch the activity to check author (fallback for calls from twist code)
      try {
        const activity = await this.db
          .selectFrom("thread")
          .select(["id", "created_by"])
          .where("id", "=", activityId)
          .executeTakeFirstOrThrow();

        created_by = activity.created_by;
        // Thread no longer stores mentions; note-level mentions are used for twist callbacks
        mentions = null;
      } catch {
        throw new Error(`Activity not found: ${activityId}`);
      }
    }

    // Check if the activity was created by this twist
    if (created_by === this.twistInstanceId) {
      this.requireThreadAccess(ThreadAccess.Create);
      return;
    }

    // Check if activity mentions the twist
    if (
      mentions &&
      Array.isArray(mentions) &&
      mentions.includes(this.twistInstanceId)
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
      triggering_note_mentions.includes(this.twistInstanceId)
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

    // Full access allows updating any thread in scope
    if (
      this.plotOptions?.thread?.access !== undefined &&
      this.plotOptions.thread.access >= ThreadAccess.Full
    ) {
      this.enforceApprovalGate(created_by);
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
    const { id } = await threadOps.createThread(this, thread);
    return id;
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
      const threadPriority = await this.db
        .selectFrom("thread_priority")
        .select("priority_id")
        .where("thread_id", "=", schedule.threadId)
        .where("user_id", "=", userId)
        .executeTakeFirstOrThrow();

      // Pending case-A rows have priority_id NULL — fall back to the
      // user's root priority for downstream contact-add logic.
      let scheduleContactsPriorityId = threadPriority.priority_id;
      if (scheduleContactsPriorityId == null) {
        const root = await this.db
          .selectFrom("priority")
          .select("id")
          .where("user_id", "=", userId)
          .where(sql<number>`nlevel(path)`, "=", 1)
          .where("archived_at", "is", null)
          .orderBy("created_at", "asc")
          .executeTakeFirstOrThrow();
        scheduleContactsPriorityId = root.id;
      }

      await processScheduleContacts(
        this,
        result.id,
        schedule.contacts,
        scheduleContactsPriorityId
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

  // Admin read operations
  async getThreads(options?: {
    priorityId?: Uuid;
    includeDescendants?: boolean;
    includeArchived?: boolean;
    limit?: number;
    offset?: number;
  }): Promise<Thread[]> {
    this.requireThreadAccess(ThreadAccess.Full);
    return threadOps.getThreads(this, options);
  }

  async getPriorities(options?: {
    parentId?: Uuid;
    includeDescendants?: boolean;
    includeArchived?: boolean;
  }): Promise<Priority[]> {
    return priorityOps.getPriorities(this, options);
  }

  // Link update operation
  async updateLink(link: LinkUpdate): Promise<void> {
    return linkOps.updateLink(this, link);
  }

  // Plan operations
  createPlan(options: {
    title: string;
    operations: PlanOperation[];
    callback: Callback;
  }): Action {
    if (!this.plotOptions?.requireApproval) {
      throw new Error(
        "createPlan() requires requireApproval: true in Plot options"
      );
    }
    return {
      type: ActionType.plan,
      title: options.title,
      operations: options.operations,
      callback: options.callback,
    };
  }
}
