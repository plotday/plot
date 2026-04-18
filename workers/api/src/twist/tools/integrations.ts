import { sql, type Kysely } from "kysely";

import {
  type Actor,
  type ActorId,
  ActorType,
  type Action,
  ActionType,
  type Link,
  type NewContact,
  type NewLinkWithNotes,
  type Note,
  type Thread,
  type ThreadMeta,
} from "@plotday/twister/plot";
import { type Callback } from "@plotday/twister/tools/callbacks";
import { Tag } from "@plotday/twister/tag";
import {
  type ArchiveLinkFilter,
  type AuthProvider,
  type AuthToken,
  type Authorization,
  type Channel,
  type LinkTypeConfig,
  type SyncContext,
  type Integrations as IAuth,
} from "@plotday/twister/tools/integrations";
import type { Uuid } from "@plotday/twister/utils/uuid";

import type { Json } from "@plotday/db";
import type { DB } from "../../db-types";
import { type Bindings, type TwistEnvironment } from "../../env";
import {
  extractUserId,
  PROVIDER_CONFIGS,
  type ProviderData,
  type StoredTokenData,
} from "../../provider";
import { CallbacksState } from "../../state/callbacks";
import { classifyInviteable } from "../../state/contact-classifier";
import superjson from "superjson";

import type { Storage } from "../../state/storage";
import { createLogger } from "@plotday/worker-util";
import { rpc, rpcUser } from "../../rpc";
import { getEffectivePlan } from "../../utils/plan";
import { getSyncHistoryMinDate, type PlanKey } from "../../utils/limits";
import { getRpcFunctionName } from "../../utils/rpc";
import { invokeCallback } from "../invoke-callback";
import { fromDbLink } from "./plot/converters";
import type { Plot } from "./plot/index";
import type { Store } from "./store";
import { Tool } from "./tool";
import { createSchedule } from "../../app/sync/smart-schedule";
import { unarchiveDoneLinksOnThread } from "../../app/sync/link-tags";

/** Internal provider config used by the Integrations tool. */
type IntegrationProviderConfig = {
  provider: AuthProvider;
  scopes: string[];
  optionalScopes?: Array<{
    id: string;
    label: string;
    description?: string;
    scopes: string[];
    default: boolean;
  }>;
  linkTypes?: LinkTypeConfig[];
  getChannels: (auth: Authorization, token: AuthToken) => Promise<Channel[]>;
  onChannelEnabled: (channel: Channel, context?: SyncContext) => Promise<void>;
  onChannelDisabled: (channel: Channel) => Promise<void>;
  onLinkUpdated?: (link: Link) => Promise<void>;
  onNoteCreated?: (note: Note, meta: ThreadMeta) => Promise<void>;
};

type IntegrationOptions = {
  providers: IntegrationProviderConfig[];
};

const AUTH_EMAIL_CONFLICT_ERROR = "AuthEmailConflictError";

type AuthState = {
  provider: AuthProvider;
  scopes: string[];
  codeVerifier?: string; // Optional for Google Sign-In flows
  timestamp?: number; // Optional for Google Sign-In flows
  callback?: Callback;
  enabledScopeGroups?: string[];
};

type ChannelConfig = {
  enabled: boolean;
  enabledBy?: ActorId;
  title?: string | null;
};

type PendingActAs = {
  callbackToken: Callback;
  activityId: Uuid;
  noteId?: string;
};

// @ts-ignore - class correctly implements IAuth but TS can't verify due to Kysely type differences
export class Integrations extends Tool implements IAuth {
  private store: Store;
  private env: Bindings;
  private db: Kysely<DB>;
  private twistInstanceId: string;
  // These are callbacks we create and call
  private callbacks: DurableObjectStub<CallbacksState>;
  private _twistId: string;
  private _environment: TwistEnvironment;
  private path: string[];
  private providerConfigs: IntegrationProviderConfig[];
  /** Source metadata passed from factory when the twist is a Source. */
  private sourceProvider: { provider?: string; scopes?: string[]; linkTypes?: any[]; shared?: boolean; keyOption?: string } | null = null;
  /** Cached sync history min date (undefined = not computed yet, null = no limit). */
  private _syncHistoryMin: Date | null | undefined = undefined;
  /**
   * Extract provider metadata from integration options during deployment.
   * Returns provider/scopes pairs without lifecycle callbacks.
   */
  static Providers(
    options?: IntegrationOptions
  ): Array<{ provider: string; scopes: string[]; linkTypes?: any[] }> {
    if (!options?.providers) return [];
    return options.providers.map((p) => ({
      provider: p.provider,
      scopes: [...p.scopes],
      linkTypes: p.linkTypes ?? [],
    }));
  }

  private static GetStub(
    callbacks: DurableObjectNamespace<CallbacksState>,
    twistInstanceId: string
  ) {
    const callbacksId = callbacks.idFromName(twistInstanceId);
    return callbacks.get(callbacksId);
  }

  constructor(options: {
    store: Store;
    env: Bindings;
    db: Kysely<DB>;
    twistInstanceId: string;
    twistId: string;
    environment: TwistEnvironment;
    path: string[];
    integrationOptions?: IntegrationOptions;
    /** Source metadata (provider, scopes, linkTypes, auth model) from the Source class. Set by factory for sources. */
    sourceProvider?: { provider?: string; scopes?: string[]; linkTypes?: any[]; shared?: boolean; keyOption?: string } | null;
  }) {
    super();
    this.store = options.store;
    this.env = options.env;
    this.db = options.db;
    this.twistInstanceId = options.twistInstanceId;
    this._twistId = options.twistId;
    this._environment = options.environment;
    this.callbacks = Integrations.GetStub(
      options.env.CALLBACKS,
      options.twistInstanceId
    );
    this.path = options.path;
    this.sourceProvider = options.sourceProvider ?? null;
    // Provider config callbacks (onChannelEnabled, onChannelDisabled, getChannels)
    // are no longer called as RPC stubs — they're returned as __dispatch info
    // and invoked locally by the twist worker entrypoint with proper this binding.
    // No need to dup any RPC stubs.
    this.providerConfigs = options.integrationOptions?.providers ?? [];

    // For sources using the new API (sourceProvider set), synthesize a provider config
    // so existing methods that read providerConfigs still work.
    // Skip for no-provider connectors (provider is undefined).
    if (this.sourceProvider?.provider && this.providerConfigs.length === 0) {
      this.providerConfigs = [{
        provider: this.sourceProvider.provider as AuthProvider,
        scopes: this.sourceProvider.scopes ?? [],
        linkTypes: this.sourceProvider.linkTypes,
        // Placeholder callbacks — never called directly, dispatch uses sourceMethod instead
        getChannels: async () => [],
        onChannelEnabled: async () => {},
        onChannelDisabled: async () => {},
      }];
    }
  }

  /**
   * Returns the sync history min date for this twist instance, based on the
   * owner's effective plan. Cached after first call.
   */
  async getSyncHistoryMin(): Promise<Date | null> {
    if (this._syncHistoryMin !== undefined) return this._syncHistoryMin;

    const twistInstance = await this.db
      .selectFrom("twist_instance")
      .select(["owner_id", "team_id"])
      .where("id", "=", this.twistInstanceId)
      .executeTakeFirst();

    if (!twistInstance?.owner_id) {
      this._syncHistoryMin = null;
      return null;
    }

    let plan: PlanKey;
    if (twistInstance.team_id) {
      const teamSub = await this.db
        .selectFrom("team_subscription")
        .select(["plan", "status"])
        .where("team_id", "=", String(twistInstance.team_id))
        .executeTakeFirst();
      plan =
        teamSub?.status === "active"
          ? (teamSub.plan as PlanKey)
          : "free";
    } else {
      const effective = await getEffectivePlan(this.db, twistInstance.owner_id);
      plan = effective.plan;
    }

    this._syncHistoryMin = getSyncHistoryMinDate(plan);
    return this._syncHistoryMin;
  }

  /**
   * Builds the SyncContext to pass to onChannelEnabled.
   */
  private async buildSyncContext(): Promise<SyncContext> {
    const syncHistoryMin = await this.getSyncHistoryMin();
    return syncHistoryMin ? { syncHistoryMin } : {};
  }

  // ============================================================================
  // Public API (implements IAuth interface)
  // ============================================================================

  /**
   * Get a token for a channel.
   * Returns the token of the user who enabled sync on the given channel.
   * Supports both get(channelId) and get(provider, channelId) signatures.
   */
  async get(channelIdOrProvider: string, channelId?: string): Promise<AuthToken | null> {
    // Support both signatures: get(channelId) and get(provider, channelId)
    let provider: AuthProvider;
    let resolvedChannelId: string;
    if (channelId !== undefined) {
      provider = channelIdOrProvider as AuthProvider;
      resolvedChannelId = channelId;
    } else {
      // Single-arg form: use the first provider from config
      provider = this.providerConfigs[0]?.provider;
      resolvedChannelId = channelIdOrProvider;
      // For key-based connectors with no OAuth providers, resolve the key
      if (!provider && this.sourceProvider?.keyOption) {
        return this.getKeyToken(resolvedChannelId);
      }
      if (!provider) return null;
    }

    // Look up channel config to find who enabled it
    const config = await this.getChannelConfig(provider, resolvedChannelId);

    if (config?.enabled && config.enabledBy) {
      return this.getActorToken(provider, config.enabledBy);
    }

    // Migration fallback: no channel_config exists for pre-redesign users.
    // Find any actor with a valid token for this provider.
    const tokenKeys = await this.store.list(`auth_token:${provider}:`);
    for (const key of tokenKeys) {
      const actorId = key.slice(`auth_token:${provider}:`.length) as ActorId;
      const token = await this.getActorToken(provider, actorId);
      if (token) {
        // Auto-create channel_config so subsequent calls use the fast path
        await this.store.set(`channel_config:${provider}:${channelId}`, {
          enabled: true,
          enabledBy: actorId,
        } satisfies ChannelConfig);
        return token;
      }
    }
    return null;
  }

  /**
   * Resolve an API key for key-based connectors.
   * For individual keys, looks up the channel enabler's per-user key from secure_option.
   * For shared keys, resolves from the shared config (Options tool).
   */
  private async getKeyToken(channelId: string): Promise<AuthToken | null> {
    const keyOption = this.sourceProvider?.keyOption;
    if (!keyOption) return null;

    // Look up who enabled this channel
    const config = await this.getChannelConfig("_options" as AuthProvider, channelId);
    const enabledByUserId = config?.enabledBy;

    if (!this.sourceProvider?.shared && enabledByUserId) {
      // Individual key: look up per-user encrypted key
      const { resolveSecureOptions } = await import("../../utils/secure-options");
      const twist = await this.db
        .selectFrom("twist")
        .select("options_schema")
        .where("id", "=", this._twistId)
        .executeTakeFirst();
      const optSchema = twist?.options_schema as Record<string, unknown> | null;
      if (!optSchema || !this.env.AI_KEY_ENCRYPTION_KEY) return null;

      // Resolve the user who enabled the channel (enabledBy is actorId = userId for key connectors)
      const resolved = await resolveSecureOptions(
        this.db,
        this.env.AI_KEY_ENCRYPTION_KEY,
        this.twistInstanceId,
        { [keyOption]: optSchema[keyOption] } as any,
        {},
        enabledByUserId as string
      );

      const key = resolved[keyOption];
      if (typeof key === "string" && key.length > 0) {
        return { token: key, scopes: [] };
      }
    }

    // Shared key or fallback: the key is in the shared Options (resolved by the factory at runtime)
    // The connector should read it via this.tools.options directly
    return null;
  }

  /**
   * Execute a callback as a specific actor, requesting auth if needed.
   */
  async actAs(
    provider: AuthProvider,
    actorId: ActorId,
    activityId: Uuid,
    callback: (token: AuthToken, ...args: any[]) => any,
    ...extraArgs: any[]
  ): Promise<void> {
    // Check if actor already has a token
    const token = await this.getActorToken(provider, actorId);

    if (token) {
      // Actor has a valid token — invoke immediately via the rebuild-and-bind
      // dispatch path so `this` inside the connector method binds to the full
      // connector instance. See workers/api/src/twist/CALLBACKS.md.
      await invokeCallback(
        this.callbacks,
        this.twistInstanceId,
        callback,
        this.path.slice(0, -1),
        extraArgs,
        token
      );
      return;
    }

    // No token - create auth request for this actor
    // @ts-ignore - TS2589: Type instantiation is excessively deep and possibly infinite
    const callbackFunctionName = await getRpcFunctionName(callback);
    if (!callbackFunctionName) {
      throw new Error(
        "Cannot create callback: function has no name. Use named functions or methods."
      );
    }

    // Create callback token for the deferred callback
    const callbackToken = await this.callbacks.create({
      twistInstanceId: this.twistInstanceId,
      path: this.path.slice(0, -1), // Target parent tool
      functionName: callbackFunctionName,
      extraArgs,
    }) as unknown as Callback;

    // Store pending actAs request
    const pendingKey = `pending_auth:${provider}:${actorId}`;
    const pending = await this.store.get<PendingActAs[]>(pendingKey) ?? [];

    // Get provider config for scopes
    const providerConfig = this.providerConfigs.find(p => p.provider === provider);
    if (!providerConfig) {
      throw new Error(`No provider config found for ${provider}`);
    }

    // Create auth link
    const onAuthCallback = await this.callbacks.create({
      twistInstanceId: this.twistInstanceId,
      path: this.path,
      functionName: "onAuth",
      extraArgs: [], // onAuth will look up pending callbacks itself
    }) as unknown as Callback;

    const authLink: Action = {
      title: `Continue with ${PROVIDER_CONFIGS[provider]?.name ?? provider}`,
      type: ActionType.auth,
      provider,
      scopes: providerConfig.scopes,
      callback: onAuthCallback,
    };

    // Create private note on the activity for this actor
    const noteId = crypto.randomUUID();
    const pendingEntry: PendingActAs = {
      callbackToken,
      activityId,
      noteId,
    };
    pending.push(pendingEntry);
    await this.store.set(pendingKey, pending);

    // Store the auth link info for the API to create the note
    // The actual note creation happens via the Plot built-in tool
    await this.store.set(`actAs_auth_link:${noteId}`, {
      actorId,
      activityId,
      provider,
      authLink,
    });
  }

  /**
   * Declare what channels an actor has access to.
   * Also updates link_types on any already-enabled channels.
   */
  async setChannels(
    provider: AuthProvider,
    actorId: ActorId,
    channels: Channel[]
  ): Promise<void> {
    await this.store.set(`channel_access:${provider}:${actorId}`, channels);

    // Update link_types on existing channels (regardless of enabled state).
    // Offset updated_at by 1ms to ensure the change is picked up by the
    // next sync pull (the cursor uses millisecond-truncated timestamps).
    const flat = this.flattenChannels(channels);
    const futureDate = new Date(Date.now() + 1);
    for (const channel of flat) {
      if (channel.linkTypes) {
        await this.db
          .updateTable("channel")
          .set({
            link_types: JSON.stringify(channel.linkTypes) as any,
            updated_at: futureDate,
          })
          .where("twist_instance_id", "=", this.twistInstanceId)
          .where("channel_id", "=", channel.id)
          .execute();
      }
    }
  }


  // ============================================================================
  // Source save operations (delegates to internal Plot instance)
  // ============================================================================

  /**
   * Get or create an internal Plot tool instance for save operations.
   * Sources use this to save threads/contacts without direct Plot access.
   * Twists are workspace-level so a single Plot instance is reused.
   */
  private _plot?: Plot;
  private getPlot(): Plot {
    if (!this._plot) {
      // Lazy import to avoid circular dependency at module load time
      // eslint-disable-next-line @typescript-eslint/no-require-imports
      const { Plot: PlotClass } = require("./plot/index") as { Plot: typeof Plot };
      this._plot = new PlotClass({
        db: this.db,
        twistInstanceId: this.twistInstanceId,
        options: {
          thread: { access: 1 /* ThreadAccess.Create */ },
        },
        env: this.env,
      });
    }
    return this._plot!;
  }

  /**
   * Saves a link with notes. Creates both a thread (container) and a link
   * (external entity). Priority resolution is delegated to
   * `prepareThreadForDb`, which routes via `match_priority_for_user` for the
   * twist owner when no explicit priority is given.
   */
  async saveLink(link: NewLinkWithNotes): Promise<Uuid | null> {
    // Filter initial-sync items by plan history limit.
    // unread === false is the reliable signal for initial sync (connector convention).
    if (link.unread === false) {
      const syncHistoryMin = await this.getSyncHistoryMin();
      if (syncHistoryMin) {
        const hasRecurrence = link.schedules?.some(s => s.recurrenceRule);
        if (!hasRecurrence) {
          // Determine the item's date from the first schedule start or link created
          const itemDate = this.extractLinkDate(link);
          if (itemDate && itemDate < syncHistoryMin) {
            return null;
          }
        }
      }
    }

    const plot = this.getPlot();
    const threadId = await plot.createLink(link);

    // Propagate status tags to the thread
    await this.propagateLinkStatusTags(plot, threadId);

    // Create task schedule for assigned links
    await this.createTaskScheduleForLink(threadId);

    return threadId;
  }

  /**
   * Extracts the most relevant date from a link for sync history filtering.
   * Uses the first schedule's start time (for calendar events) or the
   * link's created date as fallback.
   */
  private extractLinkDate(link: NewLinkWithNotes): Date | null {
    // Prefer schedule start time (most relevant for calendar events)
    const scheduleStart = link.schedules?.[0]?.start;
    if (scheduleStart) {
      return typeof scheduleStart === "string" ? new Date(scheduleStart) : scheduleStart;
    }
    // Fall back to link created date
    if (link.created) {
      return link.created instanceof Date ? link.created : new Date(link.created);
    }
    return null;
  }

  /**
   * Saves contacts to the source's priority.
   * Delegates to an internal Plot instance.
   */
  async saveContacts(contacts: NewContact[]): Promise<Actor[]> {
    const plot = this.getPlot();
    return plot.addContacts(contacts);
  }

  /**
   * Archives links matching the given filter that were created by this source.
   * For each archived link's thread, if no other active links remain,
   * the thread is also archived. Notifies sync DOs for affected priorities.
   */
  async archiveLinks(filter: ArchiveLinkFilter): Promise<void> {
    const filterJson: Record<string, unknown> = {};
    if (filter.channelId !== undefined) filterJson.channelId = filter.channelId;
    if (filter.type !== undefined) filterJson.type = filter.type;
    if (filter.status !== undefined) filterJson.status = filter.status;
    if (filter.meta !== undefined) filterJson.meta = filter.meta;

    // Wrap in transaction so Hyperdrive sees the mutating RPC as a write
    const affectedPriorityIds = await this.db.transaction().execute(async (trx) => {
      return await rpc(trx, "archive_links", {
        p_created_by: this.twistInstanceId,
        // @ts-ignore - filterJson is valid JSON but Record<string, unknown> doesn't satisfy the strict Json type
        p_filter: filterJson,
      }) as unknown as string[] | null;
    });

    if (affectedPriorityIds && affectedPriorityIds.length > 0) {
      const plot = this.getPlot();
      await plot.notifySyncDOs(new Set(affectedPriorityIds));
    }
  }

  /**
   * Sets or clears todo status on a thread owned by this source.
   * Looks up the thread by source URL, then upserts or archives a per-user schedule.
   */
  async setThreadToDo(
    source: string,
    actorId: ActorId,
    todo: boolean,
    options?: { date?: Date | string }
  ): Promise<void> {
    const logger = createLogger({ twist_instance_id: this.twistInstanceId });

    // Look up the link+thread by source URL and created_by
    const link = await this.db
      .selectFrom("link")
      .select(["id", "thread_id"])
      .where("source", "=", source)
      .where("created_by", "=", this.twistInstanceId)
      .executeTakeFirst();

    if (!link?.thread_id) {
      logger.warn(`setThreadToDo: no link found for source=${source}`);
      return;
    }

    // Resolve the user_id from the actorId (contact table)
    const contact = await this.db
      .selectFrom("contact")
      .select("user_id")
      .where("id", "=", actorId)
      .executeTakeFirst();

    if (!contact?.user_id) {
      logger.warn(`setThreadToDo: no user_id for actorId=${actorId}`);
      return;
    }

    if (todo) {
      // Upsert a per-user schedule. With no explicit date, use the epoch
      // "Now" sentinel (1970-01-01) so the thread lands in the current
      // to-do bucket rather than being scheduled for a specific day.
      let dateStr: string;
      if (options?.date) {
        dateStr = typeof options.date === "string"
          ? options.date
          : options.date.toISOString().slice(0, 10);
      } else {
        dateStr = "1970-01-01";
      }

      const dbSchedule: Record<string, unknown> = {
        thread_id: link.thread_id,
        user_id: contact.user_id,
        on: `[${dateStr},)`,
      };

      await rpcUser(this.db, "upsert_schedule", {
        user_id: contact.user_id,
        p_schedule: dbSchedule as Json,
      });

      // Lift this user's per-user archive so the thread appears in their agenda.
      await this.db
        .updateTable("thread_priority")
        .set({ archived_at: null })
        .where("thread_id", "=", link.thread_id)
        .where("user_id", "=", contact.user_id)
        .where("archived_at", "is not", null)
        .execute();

      // Flip any done-status links (e.g. "archived") back to a non-done
      // status so the link widget stops saying "Archived" and Tag.Done is
      // cleared from the thread.
      try {
        await unarchiveDoneLinksOnThread(this.db, link.thread_id);
      } catch (error) {
        logger.warn("setThreadToDo: unarchiveDoneLinksOnThread failed", {
          thread_id: link.thread_id,
          error: error instanceof Error ? error.message : String(error),
        });
      }
    } else {
      // Archive the per-user schedule for this thread
      await this.db
        .updateTable("schedule")
        .set({ archived_at: new Date() })
        .where("thread_id", "=", link.thread_id)
        .where("user_id", "=", contact.user_id)
        .where("occurrence", "is", null)
        .where("archived_at", "is", null)
        .execute();
    }

    // Notify the user's sync DO so the Flutter client picks up the change
    // in real time. setThreadToDo is called from the twist runtime (e.g.
    // Gmail processing a star from its webhook); without this the user only
    // sees the update on the next scheduled pull.
    const tp = await this.db
      .selectFrom("thread_priority")
      .select("priority_id")
      .where("thread_id", "=", link.thread_id)
      .where("user_id", "=", contact.user_id)
      .executeTakeFirst();
    if (tp?.priority_id) {
      try {
        await this.getPlot().notifySyncDOs(new Set([tp.priority_id]));
      } catch (error) {
        logger.error("setThreadToDo: failed to notify sync DOs", error as Error, {
          thread_id: link.thread_id,
        });
      }
    }
  }

  /**
   * Check if a link type+status represents completion.
   * Checks channel-level linkTypes first, falling back to twist-level.
   */
  private isStatusDone(
    type: string | null | undefined,
    status: string | null | undefined,
    channelLinkTypes?: LinkTypeConfig[]
  ): boolean {
    if (!type || !status) return false;

    // Check channel-level linkTypes first
    const sources = channelLinkTypes ?? this.providerConfigs.flatMap((p) => p.linkTypes ?? []);
    const typeConfig = sources.find((lt) => lt.type === type);
    if (!typeConfig?.statuses) return false;
    const statusDef = typeConfig.statuses.find((s) => s.status === status);
    return statusDef?.done === true;
  }

  /**
   * Create a task schedule for the assignee of a link, if applicable.
   * Queries the link row for assignee_id, resolves the contact's user_id,
   * creates a task schedule if non-done, and always recomputes outstanding_tasks.
   */
  private async createTaskScheduleForLink(
    threadId: Uuid
  ): Promise<void> {
    try {
      // Query the link to get the resolved assignee_id
      const dbLink = await this.db
        .selectFrom("link")
        .select(["assignee_id", "type", "status"])
        .where("thread_id", "=", threadId as string)
        .where("created_by", "=", this.twistInstanceId)
        .orderBy("updated_at", "desc")
        .executeTakeFirst();

      if (!dbLink?.assignee_id) return;

      // Resolve the contact's user_id
      const contact = await this.db
        .selectFrom("contact")
        .select("user_id")
        .where("id", "=", dbLink.assignee_id)
        .executeTakeFirst();

      if (!contact?.user_id) return;

      // Create schedule only if status is not done
      const channelLinkTypes = await this.getChannelLinkTypesForThread(threadId);
      if (!this.isStatusDone(dbLink.type, dbLink.status, channelLinkTypes.length > 0 ? channelLinkTypes : undefined)) {
        await createSchedule(this.db, contact.user_id, threadId as string, "task");
      } else {
        // Archive per-user task schedule when link status is done
        await this.db
          .updateTable("schedule")
          .set({ archived_at: new Date() })
          .where("thread_id", "=", threadId as string)
          .where("user_id", "=", contact.user_id)
          .where("reason", "=", "task")
          .where("occurrence", "is", null)
          .where("archived_at", "is", null)
          .execute();
      }

      // Always recompute outstanding_tasks (handles done→undone transitions)
      await sql`SELECT recompute_outstanding_tasks(${threadId}::uuid, ${contact.user_id}::uuid)`.execute(this.db);
    } catch (error) {
      console.error("[schedule] Failed to create task schedule from link assignment:", error);
    }
  }

  /**
   * Propagate status tags from link statuses to the parent thread.
   * Uses union semantics: a tag is present if ANY link on the thread (from this twist)
   * has a status that maps to that tag. Removes the tag only when no links contribute it.
   * Checks channel-level linkTypes first, falling back to twist-level.
   */
  private async propagateLinkStatusTags(
    plot: Plot,
    threadId: Uuid
  ): Promise<void> {
    // Collect all linkTypes — check channel-level first, then twist-level
    let allLinkTypes: LinkTypeConfig[] = await this.getChannelLinkTypesForThread(threadId);
    if (allLinkTypes.length === 0) {
      allLinkTypes = this.providerConfigs.flatMap(
        (p) => p.linkTypes ?? []
      );
    }
    if (allLinkTypes.length === 0) return;

    // Collect all possible tags from all status definitions
    const allPossibleTags = new Set<number>();
    for (const lt of allLinkTypes) {
      for (const s of lt.statuses ?? []) {
        if (s.tag !== undefined) allPossibleTags.add(s.tag);
      }
    }
    if (allPossibleTags.size === 0) return;

    // Query all links on this thread from this twist to compute union of contributed tags
    const siblingLinks = await this.db
      .selectFrom("link")
      .select(["type", "status"])
      .where("thread_id", "=", threadId as string)
      .where("created_by", "=", this.twistInstanceId)
      .execute();

    const contributedTags = new Set<number>();
    for (const sibling of siblingLinks) {
      const tag = this.getStatusTag(allLinkTypes, sibling.type, sibling.status);
      if (tag !== undefined) contributedTags.add(tag);
    }

    const updatedBy = plot.getUpdatedBy();
    const syncDepth = plot.syncDepth + 1;

    // Batch insert tags that should be present
    if (contributedTags.size > 0) {
      const tagValues = [...contributedTags].map((tagId) => ({
        thread_id: threadId as string,
        occurrence: null,
        tag_id: tagId,
        actor_id: this.twistInstanceId,
        updated_by: updatedBy,
        sync_depth: syncDepth,
      }));

      await this.db
        .insertInto("thread_tag")
        .values(tagValues)
        .onConflict((oc) =>
          oc
            .columns(["actor_id", "thread_id", "occurrence", "tag_id"])
            .doUpdateSet((eb) => ({
              updated_by: eb.ref("excluded.updated_by"),
              sync_depth: eb.ref("excluded.sync_depth"),
              archived_at: null,
            }))
        )
        .execute();
    }

    // Batch archive tags that are no longer contributed
    const tagsToArchive = [...allPossibleTags].filter((t) => !contributedTags.has(t));
    if (tagsToArchive.length > 0) {
      await this.db
        .updateTable("thread_tag")
        .set({ archived_at: new Date(), updated_by: updatedBy, sync_depth: syncDepth })
        .where("thread_id", "=", threadId as string)
        .where("actor_id", "=", this.twistInstanceId)
        .where("tag_id", "in", tagsToArchive)
        .where("archived_at", "is", null)
        .execute();
    }
  }

  /**
   * Look up the tag for a given link type + status from linkType configs.
   */
  private getStatusTag(
    linkTypes: LinkTypeConfig[],
    type: string | null | undefined,
    status: string | null | undefined
  ): number | undefined {
    if (!type || !status) return undefined;
    const typeConfig = linkTypes.find((lt) => lt.type === type);
    if (!typeConfig?.statuses) return undefined;
    const statusDef = typeConfig.statuses.find((s) => s.status === status);
    return statusDef?.tag;
  }

  /**
   * Look up channel-level linkTypes for a thread's links.
   * Queries the first link on this thread from this twist, resolves its channel_id,
   * then looks up link_types from channel.
   */
  private async getChannelLinkTypesForThread(threadId: Uuid): Promise<LinkTypeConfig[]> {
    const link = await this.db
      .selectFrom("link")
      .select("channel_id")
      .where("thread_id", "=", threadId as string)
      .where("created_by", "=", this.twistInstanceId)
      .where("channel_id", "is not", null)
      .limit(1)
      .executeTakeFirst();
    if (!link?.channel_id) return [];

    const channel = await this.db
      .selectFrom("channel")
      .select("link_types")
      .where("twist_instance_id", "=", this.twistInstanceId)
      .where("channel_id", "=", link.channel_id)
      .executeTakeFirst();
    if (!channel?.link_types) return [];

    try {
      const parsed = typeof channel.link_types === "string"
        ? JSON.parse(channel.link_types)
        : channel.link_types;
      return Array.isArray(parsed) ? parsed : [];
    } catch {
      return [];
    }
  }

  /**
   * Dispatch method called by the entrypoint when synced data changes.
   * Routes link updates to the appropriate source callback.
   */
  /**
   * Builds Note and Thread SDK objects from a raw note dispatch item,
   * looking up the connector's link metadata for thread context.
   */
  private async buildNoteAndThread(item: any): Promise<{ note: Note; thread: Thread }> {
    const link = await this.db
      .selectFrom("link")
      .select(["meta", "channel_id", "source"])
      .where("thread_id", "=", item.thread_id!)
      .where("created_by", "=", this.twistInstanceId)
      .executeTakeFirst();

    const note: Note = {
      id: item.id,
      created: item.created_at ? new Date(item.created_at) : new Date(),
      thread: {
        id: item.thread_id,
        title: item.thread_title,
        priority: { id: item.priority_id },
      } as any,
      author: {
        id: item.author_id ?? item.created_by,
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
      reNote: item.re_note_id ? { id: item.re_note_id } : null,
      mentions: item.mentions || [],
      tags: item.tags || {},
      accessContacts: (item.access_contacts as any) ?? null,
      archived: item.archived_at !== null,
      actions: item.actions,
    };

    const meta: ThreadMeta = { ...(link?.meta as any ?? {}) };
    meta.channelId = link?.channel_id ?? null;
    meta.linkSource = link?.source ?? null;

    // Resolve reNote key for reply targeting
    if (item.re_note_id) {
      const reNote = await this.db
        .selectFrom("note")
        .select("key")
        .where("id", "=", item.re_note_id)
        .executeTakeFirst();
      if (reNote?.key) {
        meta.reNoteKey = reNote.key;
      }
    }

    const thread: Thread = {
      id: item.thread_id,
      title: item.thread_title,
      priority: { id: item.priority_id },
      meta,
    } as Thread;

    return { note, thread };
  }

  async dispatch(
    dispatchItem: any
  ): Promise<Array<{ optionPath?: string[]; sourceMethod?: string; args: any[]; deferredTagRemoval?: { noteId: string; actorId: string }; deferredNoteKeyUpdate?: { noteId: string } }>> {
    // Handle note dispatch for connectors with handleReplies — when a user
    // replies to a thread the connector created, the connector is auto-mentioned
    // but there's no Plot tool to handle intent matching or tag removal.
    // Route directly to onNoteCreated and defer tag removal.
    // Also handles note updates (tag changes) via onNoteUpdated.
    if (dispatchItem?.itemType === "note" && this.sourceProvider) {
      const { item, isCreate = true } = dispatchItem;
      if (!item) return [];

      const threadCreatedByThis = item.thread_created_by === this.twistInstanceId;

      // Note updates (tag changes, etc.) — route to onNoteUpdated
      // Unlike creates, updates to twist-created notes are expected (user adds tags
      // to synced messages), so we don't skip on created_by === twistInstanceId.
      if (!isCreate) {
        if (!threadCreatedByThis) return [];
        // Skip if any twist/connector made the update (prevent cross-connector loops).
        // Negative updated_by values indicate twist/API-originated writes.
        // Positive values indicate app client (user) writes.
        // Only dispatch onNoteUpdated for genuine user edits.
        if (typeof item.updated_by === "number" && item.updated_by <= 0) return [];

        const { note, thread } = await this.buildNoteAndThread(item);
        return [{ sourceMethod: "onNoteUpdated", args: [note, thread] }];
      }

      // Skip notes created by this twist (prevent loops for new notes only)
      if (item.created_by === this.twistInstanceId) return [];

      const isMentioned = (item.mentions ?? []).includes(this.twistInstanceId);

      if (isMentioned && threadCreatedByThis) {
        const { note, thread } = await this.buildNoteAndThread(item);

        return [{
          sourceMethod: "onNoteCreated",
          args: [note, thread],
          deferredTagRemoval: {
            noteId: item.id as string,
            actorId: (item.author_id ?? item.created_by) as string,
          },
          deferredNoteKeyUpdate: { noteId: item.id as string },
        }];
      }

      return [];
    }

    // Handle channel_note dispatch — route to source's onNoteCreated
    if (dispatchItem?.itemType === "channel_note" && this.sourceProvider) {
      const { item, isCreate = true } = dispatchItem;
      if (!isCreate || !item) return [];

      // Skip notes created by this twist (prevent loops)
      if (item.created_by === this.twistInstanceId) return [];

      // Skip notes created by ANY twist/connector (prevent cross-connector loops).
      // Negative updated_by indicates twist-originated writes. Channel note dispatch
      // should only fire for user-created notes (replies typed in the app), not for
      // notes created by other connectors during sync.
      if (typeof item.updated_by === "number" && item.updated_by <= 0) return [];

      // Skip notes that mention this twist on threads it created —
      // these are already dispatched via the "note" (mention) path
      const isMentioned = (item.mentions ?? []).includes(this.twistInstanceId);
      const threadCreatedByThis = item.thread_created_by === this.twistInstanceId;
      if (isMentioned && threadCreatedByThis) return [];

      const note: Note = {
        id: item.id,
        created: item.created_at ? new Date(item.created_at) : new Date(),
        thread: {
          id: item.thread_id,
          title: item.thread_title,
          priority: { id: item.priority_id },
        } as any,
        author: {
          id: item.author_id ?? item.created_by,
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
        reNote: item.re_note_id ? { id: item.re_note_id } : null,
        mentions: item.mentions || [],
        tags: item.tags || {},
        accessContacts: (item.access_contacts as any) ?? null,
        archived: item.archived_at !== null,
        actions: item.actions,
      };

      // Build thread with meta populated from link metadata
      const meta: ThreadMeta = { ...(item.link_meta as any ?? {}) };
      meta.channelId = item.link_channel_id;
      meta.linkSource = item.link_source;

      // Resolve reNote key for reply targeting
      if (item.re_note_id) {
        const reNote = await this.db
          .selectFrom("note")
          .select("key")
          .where("id", "=", item.re_note_id)
          .executeTakeFirst();
        if (reNote?.key) {
          meta.reNoteKey = reNote.key;
        }
      }

      // Build a Thread object with meta populated for the onNoteCreated callback
      const thread = {
        id: item.thread_id,
        title: item.thread_title,
        priority: { id: item.priority_id },
        meta,
      };

      return [{ sourceMethod: "onNoteCreated", args: [note, thread], deferredNoteKeyUpdate: { noteId: item.id as string } }];
    }

    // Handle thread_schedule dispatch — route to connector's onThreadToDo.
    // The Plot-tool dispatch path requires plotOptions.thread.access, which
    // connectors don't declare, so dispatch from here for connector-owned threads.
    if (dispatchItem?.itemType === "thread_schedule" && this.sourceProvider) {
      const { item } = dispatchItem;
      if (!item?.thread_id) return [];

      // Only dispatch for threads this connector created
      const link = await this.db
        .selectFrom("link")
        .select(["meta", "channel_id", "source"])
        .where("thread_id", "=", item.thread_id as string)
        .where("created_by", "=", this.twistInstanceId)
        .executeTakeFirst();
      if (!link) return [];

      const threadRow = await this.db
        .selectFrom("thread")
        .select(["id", "title", "archived_at"])
        .where("id", "=", item.thread_id as string)
        .executeTakeFirst();
      if (!threadRow) return [];

      const meta: ThreadMeta = {
        ...((link.meta as Record<string, unknown>) ?? {}),
        channelId: link.channel_id ?? null,
        linkSource: link.source ?? null,
      } as ThreadMeta;

      // Resolve actor from the schedule's user_id via the user's primary linked contact
      let actor: Actor = {
        id: (item.user_id as ActorId) ?? ("" as ActorId),
        type: ActorType.User,
        name: null,
      };
      if (item.user_id) {
        const contact = await this.db
          .selectFrom("user_contact as uc")
          .innerJoin("contact as c", "c.id", "uc.contact_id")
          .select(["c.id", "c.name"])
          .where("uc.user_id", "=", item.user_id as string)
          .where("uc.linked", "=", true)
          .where("uc.primary", "=", true)
          .where("uc.archived_at", "is", null)
          .executeTakeFirst();
        if (contact) {
          actor = {
            id: contact.id as ActorId,
            name: contact.name ?? null,
            type: ActorType.User,
          };
        }
      }

      // todo=true if schedule is active (on/at set); false if cleared
      const todo = item.on != null || item.at != null;

      // Extract date from schedule's on (daterange) or at (tstzrange)
      let date: Date | undefined;
      if (item.on != null) {
        // daterange format: [start,end) — extract start date
        const match = String(item.on).match(/[[(](\d{4}-\d{2}-\d{2})/);
        if (match) date = new Date(match[1]);
      } else if (item.at != null) {
        // tstzrange format: ["start","end") — extract start timestamp
        const match = String(item.at).match(/[[("]([\d\-T:.+Z]+)/);
        if (match) date = new Date(match[1]);
      }

      const thread: Partial<Thread> = {
        id: threadRow.id as Uuid,
        title: threadRow.title ?? "",
        archived: threadRow.archived_at !== null,
        meta,
      };

      return [{
        sourceMethod: "onThreadToDo",
        args: [thread, actor, todo, { date }],
      }];
    }

    // Handle schedule_contact dispatch — route to connector's onScheduleContactUpdated.
    // The Plot-tool dispatch path requires plotOptions.thread.access, which
    // connectors don't declare, so dispatch from here for connector-owned link schedules.
    if (dispatchItem?.itemType === "schedule_contact" && this.sourceProvider) {
      const { item } = dispatchItem;
      if (!item || item.archived_at) return [];

      // Only dispatch when the contact is one of the twist owner's linked contacts.
      // Other attendees' rows come from sync, not user action, and write-back only
      // makes sense for the user who connected the external account.
      const ownerLinked = await this.db
        .selectFrom("twist_instance as pt")
        .innerJoin("user_contact as uc", (join) =>
          join
            .onRef("uc.user_id", "=", "pt.owner_id")
            .on("uc.contact_id", "=", item.contact_id as string)
        )
        .select("pt.id")
        .where("pt.id", "=", this.twistInstanceId)
        .where("uc.linked", "=", true)
        .where("uc.archived_at", "is", null)
        .executeTakeFirst();
      if (!ownerLinked) return [];

      // Resolve link (and thread_id) for this schedule_contact. Link schedules
      // have schedule.thread_id = NULL, so we look up via link_id when available.
      let link = item.link_id
        ? await this.db
            .selectFrom("link")
            .select(["thread_id", "meta", "channel_id", "source"])
            .where("id", "=", item.link_id)
            .where("created_by", "=", this.twistInstanceId)
            .executeTakeFirst()
        : undefined;
      if (!link && item.thread_id) {
        link = await this.db
          .selectFrom("link")
          .select(["thread_id", "meta", "channel_id", "source"])
          .where("thread_id", "=", item.thread_id as string)
          .where("created_by", "=", this.twistInstanceId)
          .executeTakeFirst();
      }
      if (!link?.thread_id) return [];

      const threadRow = await this.db
        .selectFrom("thread")
        .select(["id", "title", "archived_at"])
        .where("id", "=", link.thread_id as string)
        .executeTakeFirst();
      if (!threadRow) return [];

      const meta: ThreadMeta = {
        ...((link.meta as Record<string, unknown>) ?? {}),
        channelId: link.channel_id ?? null,
        linkSource: link.source ?? null,
      } as ThreadMeta;

      const thread: Partial<Thread> = {
        id: threadRow.id as Uuid,
        title: threadRow.title ?? "",
        archived: threadRow.archived_at !== null,
        meta,
      };

      const actor: Actor = {
        id: item.contact_id as ActorId,
        type: ActorType.Contact,
        name: null,
      };

      return [{
        sourceMethod: "onScheduleContactUpdated",
        args: [thread, item.schedule_id, item.contact_id, item.status ?? null, actor],
      }];
    }

    if (dispatchItem?.itemType !== "link" && dispatchItem?.itemType !== "channel_link") return [];

    // For channel_link creates, the connector itself created the link — no callback needed
    if (dispatchItem.itemType === "channel_link" && dispatchItem.isCreate) return [];

    const dbLink = dispatchItem.item;
    if (!dbLink) return [];

    // Convert DB link to SDK Link type
    const sdkLink = fromDbLink(dbLink);

    // Source pattern: dispatch directly to source method
    if (this.sourceProvider) {
      return [{ sourceMethod: "onLinkUpdated", args: [sdkLink] }];
    }

    // Legacy pattern: dispatch via option path
    const providerIndex = this.providerConfigs.findIndex(
      (p) => p.onLinkUpdated
    );
    if (providerIndex < 0) return [];

    return [
      {
        optionPath: ["providers", String(providerIndex), "onLinkUpdated"],
        args: [sdkLink],
      },
    ];
  }

  // ============================================================================
  // Internal methods (called by API endpoints)
  // ============================================================================

  /**
   * Get a token directly for an actor (by actor ID).
   * Used internally and by API endpoints.
   */
  async getActorToken(provider: AuthProvider, actorId: ActorId): Promise<AuthToken | null> {
    // Direct lookup by provider + actor ID
    const tokenKey = `auth_token:${provider}:${actorId}`;
    let tokenData = await this.store.get<StoredTokenData>(tokenKey);
    let foundTokenKey = tokenKey;

    // Fallback: find a linked contact (same user_id) that has authed
    if (!tokenData) {
      const contact = await this.db
        .selectFrom("contact")
        .select("user_id")
        .where("id", "=", actorId)
        .executeTakeFirst();

      if (contact?.user_id) {
        const linkedContacts = await this.db
          .selectFrom("contact")
          .select("id")
          .where("user_id", "=", contact.user_id)
          .where("id", "!=", actorId)
          .execute();

        for (const linked of linkedContacts) {
          const linkedKey = `auth_token:${provider}:${linked.id}`;
          tokenData = await this.store.get<StoredTokenData>(linkedKey);
          if (tokenData) {
            foundTokenKey = linkedKey;
            break;
          }
        }
      }
    }

    if (!tokenData) {
      return null;
    }

    const config = PROVIDER_CONFIGS[provider];

    // Check if token is expired
    if (tokenData.expires_at && Date.now() > tokenData.expires_at) {
      // Token is expired, try to refresh if we have a refresh token
      if (tokenData.refresh_token && tokenData.client_id) {
        try {
          const refreshedToken = await this.refreshToken({
            clientId: tokenData.client_id,
            refreshToken: tokenData.refresh_token,
            provider,
          });

          // Update stored token - preserve providerData automatically
          const updatedToken: StoredTokenData = {
            client_id: tokenData.client_id,
            access_token: refreshedToken.access_token,
            refresh_token:
              refreshedToken.refresh_token || tokenData.refresh_token || null,
            scopes: tokenData.scopes,
            expires_at: refreshedToken.expires_in
              ? Date.now() + refreshedToken.expires_in * 1000
              : null,
            providerData: tokenData.providerData, // Preserved automatically
          };
          await this.store.set(foundTokenKey, updatedToken);

          return {
            token: refreshedToken.access_token,
            scopes: tokenData.scopes,
            provider: tokenData.providerData
              ? config?.extractMetadata?.(tokenData.providerData)
              : undefined,
          };
        } catch (error) {
          const logger = createLogger({ twist_instance_id: this.twistInstanceId });
          logger.error("Failed to refresh token", error as Error, {
            provider,
            actor_id: actorId,
          });
          // Clear expired token
          await this.store.clear(foundTokenKey);
          return null;
        }
      }

      // No refresh token or refresh failed, clear expired token
      await this.store.clear(foundTokenKey);
      return null;
    }

    return {
      token: tokenData.access_token,
      scopes: tokenData.scopes,
      provider: tokenData.providerData
        ? config?.extractMetadata?.(tokenData.providerData)
        : undefined,
    };
  }

  /**
   * Handle OAuth callback after token exchange.
   * Called by the OAuth callback handler.
   */
  async onAuth(
    tokenInfo: {
      access_token: string;
      refresh_token?: string;
      expires_in?: number;
      provider: AuthProvider;
      scopes: string[];
      client_id: string;
      // Raw provider response data (will be parsed)
      [key: string]: any;
    },
    callbackToken?: Callback
  ): Promise<void> {
    const config = PROVIDER_CONFIGS[tokenInfo.provider];

    // Parse provider-specific data if handler exists (may be async)
    const providerData =
      (await config?.parseTokenResponse?.(tokenInfo)) ?? null;

    // Extract email from providerData and link to contact, building actor
    const email = this.extractEmail(providerData);
    let actor: Actor;
    try {
      actor = await this.buildActor(email);
    } catch (error) {
      throw error;
    }

    // Store provider ID mapping for source-based contact lookup
    const providerUserId = extractUserId(tokenInfo.provider, providerData);
    if (providerUserId && actor.id) {
      try {
        await this.db
          .insertInto("contact_external_account")
          .values({
            contact_id: actor.id,
            provider: tokenInfo.provider,
            account_id: providerUserId,
            data_fetched_at: new Date().toISOString(),
          })
          .onConflict((oc) =>
            oc.columns(["provider", "account_id"]).doUpdateSet((eb) => ({
              contact_id: eb.ref("excluded.contact_id"),
              data_fetched_at: eb.ref("excluded.data_fetched_at"),
            }))
          )
          .execute();
      } catch (error) {
        const logger = createLogger({ twist_instance_id: this.twistInstanceId });
        logger.error("Failed to store provider mapping", error as Error);
      }
    }

    // Store token keyed by provider + actor ID
    const tokenKey = `auth_token:${tokenInfo.provider}:${actor.id}`;
    const token: StoredTokenData = {
      client_id: tokenInfo.client_id,
      access_token: tokenInfo.access_token,
      refresh_token: tokenInfo.refresh_token ?? null,
      scopes: tokenInfo.scopes,
      expires_at: tokenInfo.expires_in
        ? Date.now() + tokenInfo.expires_in * 1000
        : null,
      providerData,
    };
    await this.store.set(tokenKey, token);

    // Store enabled scope groups if present in the auth state
    const authStateKey = `auth_state:${tokenInfo.provider}`;
    const authState = await this.store.get<AuthState>(authStateKey);
    if (authState?.enabledScopeGroups) {
      await this.store.set(
        `enabled_scope_groups:${tokenInfo.provider}:${actor.id}`,
        authState.enabledScopeGroups
      );
    }

    // Record user connection for per-user connection tracking
    const contact = await this.db
      .selectFrom("contact")
      .select("user_id")
      .where("id", "=", actor.id)
      .executeTakeFirst();
    if (contact?.user_id) {
      try {
        await this.db
          .insertInto("twist_instance_connection")
          .values({
            twist_instance_id: this.twistInstanceId,
            user_id: contact.user_id,
            provider: tokenInfo.provider,
            actor_id: actor.id,
            connected_at: new Date().toISOString(),
          })
          .onConflict((oc) =>
            oc
              .columns(["twist_instance_id", "user_id", "provider"])
              .doUpdateSet({
                actor_id: actor.id,
                connected_at: new Date().toISOString(),
              })
          )
          .execute();
      } catch (error) {
        const logger = createLogger({ twist_instance_id: this.twistInstanceId });
        logger.error("Failed to record twist_instance_connection", error as Error);
      }
    }

    // Create Authorization object
    const authorization: Authorization = {
      provider: tokenInfo.provider,
      scopes: tokenInfo.scopes,
      actor,
    };

    // 1. Process pending actAs requests for this provider + actor
    const pendingKey = `pending_auth:${tokenInfo.provider}:${actor.id}`;
    const pendingRequests = await this.store.get<PendingActAs[]>(pendingKey);

    if (pendingRequests && pendingRequests.length > 0) {
      const authToken = await this.getActorToken(tokenInfo.provider, actor.id as ActorId);
      if (authToken) {
        for (const pending of pendingRequests) {
          try {
            // Call the stored callback with the token
            using _result = await this.callbacks.callCallback(
              pending.callbackToken,
              authToken
            );
          } catch (error) {
            const logger = createLogger({ twist_instance_id: this.twistInstanceId });
            logger.error("Error executing pending actAs callback", error as Error, {
              provider: tokenInfo.provider,
              actor_id: actor.id,
            });
          }
        }
      }
      // Clean up pending requests
      await this.store.clear(pendingKey);
    }

    // 2. Call legacy callback token if provided (for backward compat / direct request() calls)
    if (callbackToken) {
      try {
        using _result = await this.callbacks.callCallback(
          callbackToken,
          authorization
        );
      } catch (error) {
        const logger = createLogger({ twist_instance_id: this.twistInstanceId });
        logger.error("Error executing original auth callback", error as Error, {
          provider: tokenInfo.provider,
          actor_id: actor.id,
        });
      }
    }

    // 3. Return dispatch for getChannels — called locally by entrypoint with proper this binding,
    // result forwarded to setChannels via forwardTo directive.
    const authToken: AuthToken = {
      token: token.access_token,
      scopes: token.scopes,
    };
    const forwardTo = {
      functionName: "setChannels",
      prependArgs: [tokenInfo.provider, actor.id],
    };

    // Source pattern: dispatch directly to source method
    if (this.sourceProvider) {
      return {
        __dispatch: [{
          sourceMethod: "getChannels",
          args: [authorization, authToken],
          forwardTo,
        }],
      } as any;
    }

    // Legacy pattern: dispatch via option path
    const providerIndex = this.providerConfigs.findIndex(
      p => p.provider === tokenInfo.provider
    );
    if (providerIndex >= 0) {
      return {
        __dispatch: [{
          optionPath: ["providers", providerIndex, "getChannels"],
          args: [authorization, authToken],
          forwardTo,
        }],
      } as any;
    }
  }

  /**
   * Remove an actor's auth for a provider.
   * Handles channel reassignment and calls onRemoved.
   */
  async removeAuth(provider: AuthProvider, actorId: ActorId): Promise<void> {
    const tokenKey = `auth_token:${provider}:${actorId}`;

    // Handle channels this actor enabled (flatten tree to check all levels)
    const actorChannelsTree = await this.getChannelAccess(provider, actorId);
    const actorChannels = this.flattenChannels(actorChannelsTree);

    // Accumulate dispatch entries for callbacks that need to run on the twist worker
    const dispatches: Array<{ optionPath?: (string | number)[]; sourceMethod?: string; args: any[] }> = [];
    const useSourceMethod = !!this.sourceProvider;
    const providerIndex = useSourceMethod ? -1 : this.providerConfigs.findIndex(p => p.provider === provider);
    const syncContext = await this.buildSyncContext();

    for (const channel of actorChannels) {
      const channelConfig = await this.getChannelConfig(provider, channel.id);

      if (channelConfig?.enabled && channelConfig.enabledBy === actorId) {
        // This actor enabled this channel - need to reassign or disable
        const newOwner = await this.findAlternateOwner(provider, channel.id, actorId);
        const configKey = `channel_config:${provider}:${channel.id}`;

        if (newOwner) {
          // Reassign: disable with old owner, enable with new
          if (useSourceMethod) {
            dispatches.push({ sourceMethod: "onChannelDisabled", args: [channel] });
          } else if (providerIndex >= 0) {
            dispatches.push({
              optionPath: ["providers", String(providerIndex), "onChannelDisabled"],
              args: [channel],
            });
          }

          await this.store.set(configKey, {
            enabled: true,
            enabledBy: newOwner,
            title: channel.title,
          } satisfies ChannelConfig);

          if (useSourceMethod) {
            dispatches.push({ sourceMethod: "onChannelEnabled", args: [channel, syncContext] });
          } else if (providerIndex >= 0) {
            dispatches.push({
              optionPath: ["providers", String(providerIndex), "onChannelEnabled"],
              args: [channel, syncContext],
            });
          }
        } else {
          // No alternate owner - disable
          if (useSourceMethod) {
            dispatches.push({ sourceMethod: "onChannelDisabled", args: [channel] });
          } else if (providerIndex >= 0) {
            dispatches.push({
              optionPath: ["providers", String(providerIndex), "onChannelDisabled"],
              args: [channel],
            });
          }

          await this.store.set(configKey, {
            enabled: false,
            title: channel.title,
          } satisfies ChannelConfig);
        }
      }
    }

    // Delete auth token and channel access
    await this.store.clear(tokenKey);
    await this.store.clear(`channel_access:${provider}:${actorId}`);

    // Remove user connection record
    try {
      await this.db
        .deleteFrom("twist_instance_connection")
        .where("twist_instance_id", "=", this.twistInstanceId)
        .where("actor_id", "=", actorId)
        .where("provider", "=", provider)
        .execute();
    } catch (error) {
      const logger = createLogger({ twist_instance_id: this.twistInstanceId });
      logger.error("Failed to remove twist_instance_connection", error as Error);
    }
    // Clean up old key if it exists
    await this.store.clear(`syncable_access:${provider}:${actorId}`);

    // Return dispatch info for the entrypoint to invoke locally
    if (dispatches.length > 0) {
      return { __dispatch: dispatches } as any;
    }
  }

  /**
   * Enable sync for a channel.
   * Called from API endpoint when user toggles sync on.
   */
  async enableSync(
    provider: AuthProvider,
    channelId: string,
    actorId: ActorId,
    title?: string
  ): Promise<void> {
    // Find the channel from the actor's channel access list
    const channels = await this.getChannelAccess(provider, actorId);
    const channelObj = this.findChannelInTree(channels, channelId);
    if (!title) {
      title = channelObj?.title;
    }

    // Extract per-channel linkTypes if available.
    // Fall back to existing channel rows for the same channel_id
    // (handles re-add after archive, where KV may not have been populated yet).
    let linkTypes = channelObj?.linkTypes ?? null;
    if (!linkTypes) {
      const existingChannel = await this.db
        .selectFrom("channel")
        .select("link_types")
        .where("channel_id", "=", channelId)
        .where("link_types", "is not", null)
        .limit(1)
        .executeTakeFirst();
      if (existingChannel?.link_types) {
        try {
          linkTypes = typeof existingChannel.link_types === "string"
            ? JSON.parse(existingChannel.link_types)
            : existingChannel.link_types;
        } catch { /* ignore parse errors */ }
      }
    }

    await this.store.set(`channel_config:${provider}:${channelId}`, {
      enabled: true,
      enabledBy: actorId,
      title: title ?? null,
    } satisfies ChannelConfig);

    // Write to channel DB table (dual-write with KV)
    await this.db
      .insertInto("channel")
      .values({
        twist_instance_id: this.twistInstanceId,
        channel_id: channelId,
        title: title ?? channelId,
        enabled: true,
        link_types: linkTypes ? JSON.stringify(linkTypes) : null,
      })
      .onConflict((oc) =>
        oc.columns(["twist_instance_id", "channel_id"]).doUpdateSet({
          enabled: true,
          title: title ?? channelId,
          link_types: linkTypes ? JSON.stringify(linkTypes) : null,
          updated_at: new Date(),
        })
      )
      .execute();

    // Return dispatch info for onChannelEnabled callback.
    // The entrypoint will invoke this locally on the twist worker with proper this binding.
    const channelArg = { id: channelId, title: title ?? channelId };
    const syncContext = await this.buildSyncContext();

    // Source pattern: dispatch directly to source method
    if (this.sourceProvider) {
      return {
        __dispatch: [{ sourceMethod: "onChannelEnabled", args: [channelArg, syncContext] }],
      } as any;
    }

    // Legacy pattern: dispatch via option path
    const providerIndex = this.providerConfigs.findIndex(p => p.provider === provider);
    if (providerIndex >= 0) {
      return {
        __dispatch: [{
          optionPath: ["providers", providerIndex, "onChannelEnabled"],
          args: [channelArg, syncContext],
        }],
      } as any;
    }
  }

  /**
   * Disable sync for a channel.
   * Called from API endpoint when user toggles sync off.
   */
  async disableSync(
    provider: AuthProvider,
    channelId: string
  ): Promise<void> {
    const existing = await this.getChannelConfig(provider, channelId);

    await this.store.set(`channel_config:${provider}:${channelId}`, {
      enabled: false,
      title: existing?.title ?? null,
    } satisfies ChannelConfig);

    // Write to channel DB table (dual-write with KV)
    await this.db
      .updateTable("channel")
      .set({ enabled: false, updated_at: new Date() })
      .where("twist_instance_id", "=", this.twistInstanceId)
      .where("channel_id", "=", channelId)
      .execute();

    // Return dispatch info for onChannelDisabled callback.
    // The entrypoint will invoke this locally on the twist worker with proper this binding.
    const channelArg = { id: channelId, title: existing?.title ?? channelId };

    // Source pattern: dispatch directly to source method
    if (this.sourceProvider) {
      return {
        __dispatch: [{ sourceMethod: "onChannelDisabled", args: [channelArg] }],
      } as any;
    }

    // Legacy pattern: dispatch via option path
    const providerIndex = this.providerConfigs.findIndex(p => p.provider === provider);
    if (providerIndex >= 0) {
      return {
        __dispatch: [{
          optionPath: ["providers", providerIndex, "onChannelDisabled"],
          args: [channelArg],
        }],
      } as any;
    }
  }

  /**
   * Get all integration data for the edit modal.
   * Returns accounts, providers, and channels.
   */
  async getIntegrationData(currentActorId?: ActorId): Promise<{
    providers: Array<{ provider: AuthProvider; scopes: string[]; optionalScopes?: any[] }>;
    accounts: Array<{
      provider: AuthProvider;
      actorId: ActorId;
      email: string | null;
      name: string | null;
      enabledScopeGroups?: string[];
    }>;
    syncables: Array<{
      provider: AuthProvider;
      id: string;
      title: string;
      enabled: boolean;
      enabledBy: ActorId | undefined;
      currentUserHasAccess: boolean;
      children?: Array<{
        provider: AuthProvider;
        id: string;
        title: string;
        enabled: boolean;
        enabledBy: ActorId | undefined;
        currentUserHasAccess: boolean;
        children?: any[];
      }>;
    }>;
  }> {
    const providers = this.providerConfigs.map(p => ({
      provider: p.provider,
      scopes: p.scopes,
      ...(p.optionalScopes ? { optionalScopes: p.optionalScopes } : {}),
    }));

    // Resolve all contact IDs belonging to the current user so we can
    // correctly mark currentUserHasAccess for linked contacts.
    const currentUserContactIds = new Set<string>();
    if (currentActorId) {
      currentUserContactIds.add(currentActorId);
      const currentContact = await this.db
        .selectFrom("contact")
        .select("user_id")
        .where("id", "=", currentActorId)
        .executeTakeFirst();
      if (currentContact?.user_id) {
        const linkedContacts = await this.db
          .selectFrom("contact")
          .select("id")
          .where("user_id", "=", currentContact.user_id)
          .execute();
        for (const c of linkedContacts) {
          currentUserContactIds.add(c.id);
        }
      }
    }

    // Collect accounts by scanning auth_token keys
    const accounts: Array<{
      provider: AuthProvider;
      actorId: ActorId;
      email: string | null;
      name: string | null;
      enabledScopeGroups?: string[];
    }> = [];

    // Track which channel IDs have access from any current-user contact
    const channelAccessByCurrentUser = new Set<string>();

    // Collect channel trees per provider (merged across actors)
    type AnnotatedChannel = {
      provider: AuthProvider;
      id: string;
      title: string;
      enabled: boolean;
      enabledBy: ActorId | undefined;
      linkTypes?: LinkTypeConfig[];
      currentUserHasAccess: boolean;
      children?: AnnotatedChannel[];
    };

    const channelTreesByProvider = new Map<AuthProvider, Channel[]>();

    for (const providerConfig of this.providerConfigs) {
      const provider = providerConfig.provider;

      // Find all actors with tokens for this provider by scanning stored keys
      const tokenKeys = await this.store.list(`auth_token:${provider}:`);
      const knownActorIds = new Set<string>();

      for (const key of tokenKeys) {
        // Parse "auth_token:{provider}:{actorId}"
        const parts = key.split(":");
        if (parts.length >= 3) {
          knownActorIds.add(parts.slice(2).join(":"));
        }
      }

      // Build accounts and collect channel trees
      for (const actorId of knownActorIds) {
        const tokenKey = `auth_token:${provider}:${actorId}`;
        const tokenData = await this.store.get<StoredTokenData>(tokenKey);
        const email = tokenData ? this.extractEmail(tokenData.providerData) : null;

        // Look up contact name and user_id
        let name: string | null = null;
        let contactUserId: string | null = null;
        if (actorId) {
          const contact = await this.db
            .selectFrom("contact")
            .select(["name", "user_id"])
            .where("id", "=", actorId)
            .executeTakeFirst();
          name = contact?.name ?? null;
          contactUserId = contact?.user_id ?? null;
        }

        // Look up stored scope group selections
        const enabledScopeGroups = await this.store.get<string[]>(
          `enabled_scope_groups:${provider}:${actorId}`
        );

        accounts.push({
          provider,
          actorId: actorId as ActorId,
          email,
          name,
          ...(enabledScopeGroups ? { enabledScopeGroups } : {}),
        });

        // Get this actor's channel access (may be a tree)
        const actorChannels = await this.getChannelAccess(provider, actorId as ActorId);

        // Track access for the current user
        if (currentUserContactIds.has(actorId)) {
          for (const s of this.flattenChannels(actorChannels)) {
            channelAccessByCurrentUser.add(`${provider}:${s.id}`);
          }

          // Self-heal: backfill twist_instance_connection for pre-existing connections
          if (contactUserId) {
            await this.db
              .insertInto("twist_instance_connection")
              .values({
                twist_instance_id: this.twistInstanceId,
                user_id: contactUserId,
                provider,
                actor_id: actorId,
                connected_at: new Date().toISOString(),
              })
              .onConflict((oc) =>
                oc
                  .columns(["twist_instance_id", "user_id", "provider"])
                  .doNothing()
              )
              .execute();
          }
        }

        // Use the first actor's tree as the canonical tree for this provider
        // (all actors with the same provider should see the same structure)
        if (!channelTreesByProvider.has(provider) && actorChannels.length > 0) {
          channelTreesByProvider.set(provider, actorChannels);
        }
      }
    }

    // Annotate channel trees with config and access info
    const annotateChannelTree = async (
      provider: AuthProvider,
      channels: Channel[]
    ): Promise<AnnotatedChannel[]> => {
      const result: AnnotatedChannel[] = [];
      for (const channel of channels) {
        const channelConfig = await this.getChannelConfig(provider, channel.id);
        const mapKey = `${provider}:${channel.id}`;

        // Resolve linkTypes: channel-level > connector-level
        const effectiveLinkTypes = channel.linkTypes
          ?? this.sourceProvider?.linkTypes as LinkTypeConfig[] | undefined
          ?? this.providerConfigs.find(p => p.provider === provider)?.linkTypes
          ?? undefined;

        const annotated: AnnotatedChannel = {
          provider,
          id: channel.id,
          title: channel.title,
          enabled: channelConfig?.enabled ?? false,
          enabledBy: channelConfig?.enabledBy,
          linkTypes: effectiveLinkTypes,
          currentUserHasAccess: channelAccessByCurrentUser.has(mapKey),
        };

        if (channel.children && channel.children.length > 0) {
          annotated.children = await annotateChannelTree(provider, channel.children);
        }

        result.push(annotated);
      }
      return result;
    };

    // Apply visibility rules recursively:
    // Show a node if it's enabled, the user has access, or any descendant matches
    const filterVisibleTree = (channels: AnnotatedChannel[]): AnnotatedChannel[] => {
      const result: AnnotatedChannel[] = [];
      for (const s of channels) {
        const filteredChildren = s.children ? filterVisibleTree(s.children) : undefined;
        const hasVisibleChildren = filteredChildren && filteredChildren.length > 0;
        if (s.enabled || s.currentUserHasAccess || hasVisibleChildren) {
          result.push({
            ...s,
            children: filteredChildren && filteredChildren.length > 0 ? filteredChildren : undefined,
          });
        }
      }
      return result;
    };

    // Build annotated and filtered channel trees per provider
    const allChannels: AnnotatedChannel[] = [];
    for (const [provider, tree] of channelTreesByProvider) {
      const annotated = await annotateChannelTree(provider, tree);
      const visible = filterVisibleTree(annotated);
      allChannels.push(...visible);
    }

    return { providers, accounts, syncables: allChannels };
  }

  /**
   * Re-calls getChannels for a provider+actor using stored token,
   * updating channel_access with the latest list.
   */
  async refreshChannels(provider: AuthProvider, actorId: ActorId): Promise<any> {
    const token = await this.getActorToken(provider, actorId);
    if (!token) return;

    const tokenKey = `auth_token:${provider}:${actorId}`;
    const tokenData = await this.store.get<StoredTokenData>(tokenKey);
    const email = tokenData ? this.extractEmail(tokenData.providerData) : null;

    const auth: Authorization = {
      provider,
      scopes: tokenData?.scopes ?? [],
      actor: {
        id: actorId,
        type: ActorType.Contact,
        email: email ?? undefined,
      },
    };

    const forwardTo = {
      functionName: "setChannels",
      prependArgs: [provider, actorId],
    };

    // Source pattern: dispatch directly to source method
    if (this.sourceProvider) {
      return {
        __dispatch: [{
          sourceMethod: "getChannels",
          args: [auth, token],
          forwardTo,
        }],
      } as any;
    }

    // Legacy pattern: dispatch via option path
    const providerIndex = this.providerConfigs.findIndex(p => p.provider === provider);
    if (providerIndex < 0) return;

    return {
      __dispatch: [{
        optionPath: ["providers", providerIndex, "getChannels"],
        args: [auth, token],
        forwardTo,
      }],
    } as any;
  }

  /**
   * Migration: populate channel_access for pre-redesign auth tokens.
   * Called during deployment upgrade phase via callPreLifecycle.
   * Scans existing auth tokens and calls getChannels for each to
   * populate channel_access so the edit modal shows channels.
   */
  async preUpgrade(): Promise<any> {
    const tokenKeys = await this.store.list("auth_token:");
    const useSourceMethod = !!this.sourceProvider;
    const dispatches: Array<{
      optionPath?: (string | number)[];
      sourceMethod?: string;
      args: any[];
      forwardTo: { functionName: string; prependArgs: any[] };
    }> = [];

    for (const key of tokenKeys) {
      // Parse "auth_token:{provider}:{actorId}"
      const parts = key.split(":");
      if (parts.length < 3) continue;
      const provider = parts[1] as AuthProvider;
      const actorId = parts.slice(2).join(":") as ActorId;

      // Skip if channel_access already exists (already migrated)
      const accessKey = `channel_access:${provider}:${actorId}`;
      const existing = await this.store.get(accessKey);
      if (existing) continue;
      // Also check old key
      const oldExisting = await this.store.get(`syncable_access:${provider}:${actorId}`);
      if (oldExisting) continue;

      // Get token
      const token = await this.getActorToken(provider, actorId);
      if (!token) continue;

      // Build Authorization for getChannels dispatch
      const tokenData = await this.store.get<StoredTokenData>(key);
      const email = tokenData ? this.extractEmail(tokenData.providerData) : null;
      const auth: Authorization = {
        provider,
        scopes: tokenData?.scopes ?? [],
        actor: {
          id: actorId,
          type: ActorType.Contact,
          email: email ?? undefined,
        },
      };

      const forwardTo = {
        functionName: "setChannels",
        prependArgs: [provider, actorId],
      };

      if (useSourceMethod) {
        dispatches.push({
          sourceMethod: "getChannels",
          args: [auth, token],
          forwardTo,
        });
      } else {
        // Find matching provider config index
        const providerIndex = this.providerConfigs.findIndex(
          (p) => p.provider === provider
        );
        if (providerIndex < 0) continue;

        dispatches.push({
          optionPath: ["providers", providerIndex, "getChannels"],
          args: [auth, token],
          forwardTo,
        });
      }
    }

    if (dispatches.length > 0) {
      return { __dispatch: dispatches } as any;
    }
  }

  // ============================================================================
  // Private helpers
  // ============================================================================

  /**
   * Read channel config with backward-compatible fallback to old storage keys.
   */

  private async getChannelConfig(provider: AuthProvider, channelId: string): Promise<ChannelConfig | null> {
    // Try channel DB table first
    const dbRow = await this.db
      .selectFrom("channel")
      .select(["enabled", "title"])
      .where("twist_instance_id", "=", this.twistInstanceId)
      .where("channel_id", "=", channelId)
      .executeTakeFirst();

    if (dbRow) {
      // DB doesn't store enabledBy — fall back to KV for that field
      const kvConfig = await this.store.get<ChannelConfig>(`channel_config:${provider}:${channelId}`);
      return {
        enabled: dbRow.enabled,
        enabledBy: kvConfig?.enabledBy,
        title: dbRow.title,
      };
    }

    // Dual-read fallback: check KV
    const config = await this.store.get<ChannelConfig>(`channel_config:${provider}:${channelId}`);
    if (config) {
      // Migrate KV data to DB lazily
      await this.db
        .insertInto("channel")
        .values({
          twist_instance_id: this.twistInstanceId,
          channel_id: channelId,
          title: config.title ?? channelId,
          enabled: config.enabled,
        })
        .onConflict((oc) => oc.columns(["twist_instance_id", "channel_id"]).doNothing())
        .execute();
      return config;
    }

    // Backward compat: read from old storage key prefix
    return await this.store.get<ChannelConfig>(`syncable_config:${provider}:${channelId}`);
  }

  /**
   * Read channel access list with backward-compatible fallback to old storage keys.
   */
  private async getChannelAccess(provider: AuthProvider, actorId: ActorId): Promise<Channel[]> {
    const channels = await this.store.get<Channel[]>(`channel_access:${provider}:${actorId}`);
    if (channels) return channels;
    // Backward compat: read from old storage key prefix
    return await this.store.get<Channel[]>(`syncable_access:${provider}:${actorId}`) ?? [];
  }

  /**
   * Find a channel by ID anywhere in a tree of channels.
   */
  private findChannelInTree(channels: Channel[], id: string): Channel | undefined {
    for (const s of channels) {
      if (s.id === id) return s;
      if (s.children) {
        const found = this.findChannelInTree(s.children, id);
        if (found) return found;
      }
    }
    return undefined;
  }

  /**
   * Flatten a tree of channels into a flat array.
   */
  private flattenChannels(channels: Channel[]): Channel[] {
    const result: Channel[] = [];
    for (const s of channels) {
      result.push(s);
      if (s.children) {
        result.push(...this.flattenChannels(s.children));
      }
    }
    return result;
  }

  private extractEmail(providerData: ProviderData | null): string | null {
    if (!providerData) {
      return null;
    }

    // Check for email field in provider data
    if ("email" in providerData && typeof providerData.email === "string") {
      return providerData.email.toLowerCase();
    }

    return null;
  }

  /**
   * Build an Actor for the authorized account. Links the email to a contact
   * and determines whether the actor is the owner (User) or a Contact.
   */
  private async buildActor(email: string | null): Promise<Actor> {
    if (!email) {
      // No email available - create a minimal actor
      return {
        id: crypto.randomUUID() as ActorId,
        type: ActorType.Contact,
      };
    }

    try {
      // Get the user_id from the twist_instance owner
      const twistInstance = await this.db
        .selectFrom("twist_instance")
        .select("owner_id")
        .where("id", "=", this.twistInstanceId)
        .executeTakeFirst();

      if (!twistInstance?.owner_id) {
        const logger = createLogger({ twist_instance_id: this.twistInstanceId });
        logger.warn("Cannot link contact: twist_instance has no owner", {
          email,
        });
        return {
          id: crypto.randomUUID() as ActorId,
          type: ActorType.Contact,
          email,
        };
      }

      const userId = twistInstance.owner_id;

      // Check if contact exists with this email
      const existingContact = await this.db
        .selectFrom("contact")
        .select(["id", "user_id", "name"])
        .where("email", "=", email)
        .executeTakeFirst();

      if (!existingContact) {
        // Create new contact linked to current user
        const newContact = await this.db
          .insertInto("contact")
          .values({
            email,
            user_id: userId,
            name: null,
            avatar_url: null,
            inviteable: classifyInviteable(email, null),
          })
          .returning(["id", "name"])
          .executeTakeFirst();

        const logger = createLogger({ twist_instance_id: this.twistInstanceId });
        logger.info("Created new contact from OAuth", { email, user_id: userId });

        // Sync to Clerk so user can sign in with this email
        await this.syncEmailToClerk(userId, email);

        // If the new contact is linked to the owner, it's a User actor
        return {
          id: (newContact?.id ?? crypto.randomUUID()) as ActorId,
          type: ActorType.Contact,
          email,
          name: newContact?.name ?? null,
        };
      }

      if (existingContact.user_id === null) {
        // Unclaimed contact - link to current user
        await this.db
          .updateTable("contact")
          .set({ user_id: userId })
          .where("id", "=", existingContact.id)
          .execute();

        const logger = createLogger({ twist_instance_id: this.twistInstanceId });
        logger.info("Linked existing contact from OAuth", {
          email,
          user_id: userId,
        });

        // Sync to Clerk so user can sign in with this email
        await this.syncEmailToClerk(userId, email);
      } else if (existingContact.user_id !== userId) {
        const error = new Error("auth_email_conflict");
        error.name = AUTH_EMAIL_CONFLICT_ERROR;
        throw error;
      }

      // If the contact is linked to the owner user, treat as User actor
      const isOwner = existingContact.user_id === userId ||
        (existingContact.user_id === null); // just linked above
      return {
        id: existingContact.id as ActorId,
        type: isOwner ? ActorType.User : ActorType.Contact,
        email,
        name: existingContact.name ?? null,
      };
    } catch (error) {
      if (error instanceof Error && error.name === AUTH_EMAIL_CONFLICT_ERROR) {
        throw error;
      }
      const logger = createLogger({ twist_instance_id: this.twistInstanceId });
      logger.error("Error building actor from email", error as Error, { email });
      // Don't throw - return a minimal actor
      return {
        id: crypto.randomUUID() as ActorId,
        type: ActorType.Contact,
        email,
      };
    }
  }

  /**
   * Sync a newly-linked email to Clerk so the user can sign in with it.
   * Non-blocking — logs errors but never throws.
   */
  private async syncEmailToClerk(userId: string, email: string): Promise<void> {
    try {
      const user = await this.db
        .selectFrom("user")
        .select("clerk_id")
        .where("id", "=", userId)
        .executeTakeFirst();
      if (!user?.clerk_id || !this.env.CLERK_SECRET_KEY) return;

      const { syncContactToClerk } = await import("../../app/link-email");
      await syncContactToClerk(this.env.CLERK_SECRET_KEY, user.clerk_id, email, {
        twist_instance_id: this.twistInstanceId,
        user_id: userId,
      });
    } catch (error) {
      const logger = createLogger({ twist_instance_id: this.twistInstanceId });
      logger.error("Failed to sync OAuth email to Clerk (non-blocking)", error as Error, {
        user_id: userId,
        email,
      });
    }
  }

  /**
   * Find an alternate actor who has access to a channel (for reassignment).
   */
  private async findAlternateOwner(
    _provider: AuthProvider,
    _channelId: string,
    _excludeActorId: ActorId
  ): Promise<ActorId | null> {
    // For now, return null - the channel will be disabled when the owner is removed.
    // A more complete implementation would scan all actors with tokens for this provider
    // and find one who has access to the channel.
    return null;
  }

  private async refreshToken({
    clientId,
    refreshToken,
    provider,
  }: {
    clientId: string;
    refreshToken: string;
    provider: AuthProvider;
  }): Promise<{
    access_token: string;
    refresh_token?: string;
    expires_in?: number;
  }> {
    const config = PROVIDER_CONFIGS[provider];
    if (!config) {
      throw new Error(`Token refresh not implemented for ${provider}`);
    }

    const clientSecret = Integrations.SecretFromId(
      this.env,
      provider,
      clientId
    );

    const params = new URLSearchParams({
      client_id: clientId,
      ...(clientSecret ? { client_secret: clientSecret } : null),
      refresh_token: refreshToken,
      grant_type: "refresh_token",
    });

    const response = await fetch(config.tokenUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: params.toString(),
    });

    if (!response.ok) {
      const errorText = await response.text();
      throw new Error(`Token refresh failed: ${response.status} ${errorText}`);
    }

    const tokenData = (await response.json()) as {
      access_token: string;
      refresh_token?: string;
      expires_in?: number;
    };
    return {
      access_token: tokenData.access_token,
      refresh_token: tokenData.refresh_token,
      expires_in: tokenData.expires_in,
    };
  }

  // ============================================================================
  // Static methods (OAuth infrastructure)
  // ============================================================================

  static async HandleOauthCallback(
    storage: DurableObjectNamespace<Storage>,
    callbacks: DurableObjectNamespace<CallbacksState>,
    params: Record<string, string>,
    env: Bindings
  ): Promise<Response> {
    try {
      const { state, error, provider, scopes, callback } = params;

      if (error) {
        const logger = createLogger();
        logger.error("OAuth error", new Error(error));
        return new Response(
          JSON.stringify({ error: `OAuth error: ${error}` }),
          {
            status: 400,
            headers: { "Content-Type": "application/json" },
          }
        );
      }

      let authState: AuthState;

      // Check if this is a Google Sign-In flow (no state) or standard OAuth (with state)
      if (!state && provider) {
        // Google Sign-In flow: validate direct parameters
        if (!provider) throw new Error("Missing provider parameter");

        const scopeArray = scopes ? scopes.split(",").map((s) => s.trim()) : [];

        authState = {
          provider: provider as AuthProvider,
          scopes: scopeArray,
          callback: callback as Callback | undefined,
          // No codeVerifier or timestamp for Google Sign-In
        };
      } else if (state) {
        // Standard OAuth flow: retrieve state from global storage
        const storageStub = storage.idFromName("auth");
        const storageObj = storage.get(storageStub);
        const rawAuthState = await storageObj.get(state);
        let retrievedAuthState: AuthState | null = null;
        if (rawAuthState) {
          try {
            retrievedAuthState = superjson.parse<AuthState>(rawAuthState);
          } catch {
            // Fallback to JSON.parse for backward compatibility
            retrievedAuthState = JSON.parse(rawAuthState) as AuthState;
          }
        }

        if (!retrievedAuthState) {
          return new Response(
            JSON.stringify({ error: "Invalid or expired state" }),
            {
              status: 400,
              headers: { "Content-Type": "application/json" },
            }
          );
        }

        authState = retrievedAuthState;

        // Check state timestamp (expire after 1 hour) - only for standard OAuth
        if (authState.timestamp && Date.now() - authState.timestamp > 3600000) {
          await storageObj.clear(state);
          const logger = createLogger();
          logger.error("State expired", {
            timestamp: authState.timestamp,
            age_ms: Date.now() - authState.timestamp,
          });
          return new Response(JSON.stringify({ error: "State expired" }), {
            status: 400,
            headers: { "Content-Type": "application/json" },
          });
        }

        // Cleanup state after successful validation
        await storageObj.clear(state);
      } else {
        // Neither state nor provider provided
        const logger = createLogger();
        logger.error("Missing both state and provider parameters");
        return new Response(
          JSON.stringify({
            error: "Missing required authentication parameters",
          }),
          {
            status: 400,
            headers: { "Content-Type": "application/json" },
          }
        );
      }

      const { code, clientId, redirectUri } = params;
      if (!code) throw new Error("Missing code parameter");
      if (!clientId) throw new Error("Missing clientId parameter");
      if (!redirectUri) throw new Error("Missing redirectUri parameter");

      // Exchange code for tokens using static helper
      // Always include code_verifier if it exists in auth state (PKCE flow)
      const tokenResponse = await Integrations.exchangeCodeForTokens({
        clientId,
        code,
        codeVerifier: authState.codeVerifier,
        provider: authState.provider,
        redirectUri,
        env,
      });

      // Call the wrapped callback (onAuth) with token info
      if (authState.callback) {
        try {
          const _result = await CallbacksState.CallCallback(
            callbacks,
            authState.callback,
            {
            // Spread all token response fields (provider-specific fields included)
            ...tokenResponse,
            // Add our metadata
            provider: authState.provider,
            scopes: authState.scopes,
            client_id: clientId,
            }
          );
        } catch (error) {
          const errorMessage =
            error instanceof Error ? error.message : String(error);
          if (errorMessage.includes(AUTH_EMAIL_CONFLICT_ERROR)) {
            return new Response(
              JSON.stringify({
                error:
                  "The email address for this service is already associated with a different Plot account. You'll need to close that account if you want to associate it with this account.",
              }),
              {
                status: 409,
                headers: { "Content-Type": "application/json" },
              }
            );
          }
          const logger = createLogger();
          logger.error("Error executing auth callback", error as Error, {
            provider: authState.provider,
          });
          // Don't fail the auth flow even if callback fails
        }
      }

      // Sign-in flow (no callback): return tokens to the client
      if (!authState.callback) {
        return new Response(
          JSON.stringify({
            id_token: tokenResponse.id_token,
            access_token: tokenResponse.access_token,
          }),
          {
            status: 200,
            headers: { "Content-Type": "application/json" },
          }
        );
      }

      return new Response(
        JSON.stringify({
          message: "Authentication successful! You can close this window.",
        }),
        {
          status: 200,
          headers: { "Content-Type": "application/json" },
        }
      );
    } catch (error) {
      const logger = createLogger();
      logger.error("Error handling OAuth callback", error as Error);
      const errorMessage =
        error instanceof Error ? error.message : "Unknown error";
      return new Response(
        JSON.stringify({ error: `Authentication failed: ${errorMessage}` }),
        {
          status: 500,
          headers: { "Content-Type": "application/json" },
        }
      );
    }
  }

  private static GenerateRandomString(length: number): string {
    const charset =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_~";
    const values = crypto.getRandomValues(new Uint8Array(length));
    return Array.from(values)
      .map((x) => charset[x % charset.length])
      .join("");
  }

  private static GenerateCodeVerifier(): string {
    return Integrations.GenerateRandomString(128);
  }

  private static async GenerateCodeChallenge(
    codeVerifier: string
  ): Promise<string> {
    const encoder = new TextEncoder();
    const data = encoder.encode(codeVerifier);
    const digest = await crypto.subtle.digest("SHA-256", data);

    // Convert to base64url
    return btoa(String.fromCharCode(...new Uint8Array(digest)))
      .replace(/\+/g, "-")
      .replace(/\//g, "_")
      .replace(/=/g, "");
  }

  private static async exchangeCodeForTokens({
    code,
    codeVerifier,
    provider,
    redirectUri,
    clientId,
    env,
  }: {
    code: string;
    codeVerifier?: string;
    provider: AuthProvider;
    redirectUri: string;
    clientId: string;
    env: Bindings;
  }): Promise<{
    access_token: string;
    refresh_token?: string;
    expires_in?: number;
    [key: string]: any; // Allow any provider-specific fields
  }> {
    const config = PROVIDER_CONFIGS[provider];
    if (!config) {
      throw new Error(`Token exchange not implemented for ${provider}`);
    }

    const clientSecret = Integrations.SecretFromId(env, provider, clientId);

    const params = new URLSearchParams({
      client_id: clientId,
      ...(clientSecret ? { client_secret: clientSecret } : null),
      code,
      grant_type: "authorization_code",
      redirect_uri: redirectUri,
      ...(codeVerifier ? { code_verifier: codeVerifier } : {}),
    });

    const response = await fetch(config.tokenUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: params.toString(),
    });

    if (!response.ok) {
      const errorText = await response.text();
      throw new Error(`Token exchange failed: ${response.status} ${errorText}`);
    }

    const tokenData = (await response.json()) as any;

    // Return the raw token data - parsing will happen in onAuth via config.parseTokenResponse
    return tokenData;
  }

  static async GenerateAuthUrl({
    provider,
    scopes,
    callback,
    redirectUri,
    platform,
    env,
    storage,
    enabledScopeGroups,
  }: {
    provider: AuthProvider;
    scopes: string[];
    callback?: Callback;
    redirectUri: string;
    platform?: "ios" | "android" | "desktop";
    env: Bindings;
    storage: DurableObjectNamespace<Storage>;
    enabledScopeGroups?: string[];
  }): Promise<{ url: string; clientId: string; state: string } | null> {
    const config = PROVIDER_CONFIGS[provider];
    if (!config) {
      const logger = createLogger();
      logger.error("Provider not supported", { provider });
      throw new Error(`Provider ${provider} not supported`);
    }

    // Merge email scopes with requested scopes
    const emailScopes = config.emailScopes ?? [];
    const allScopes = Array.from(new Set([...scopes, ...emailScopes]));

    // Generate fresh PKCE parameters for this specific OAuth flow
    const codeVerifier = Integrations.GenerateCodeVerifier();
    const codeChallenge = await Integrations.GenerateCodeChallenge(
      codeVerifier
    );

    // Use global auth storage
    const storageStub = storage.idFromName("auth");
    const storageObj = storage.get(storageStub);

    // Generate unique state and store globally
    const state = crypto.randomUUID();
    const authState: AuthState = {
      provider,
      scopes: allScopes,
      codeVerifier,
      timestamp: Date.now(),
      callback,
      enabledScopeGroups,
    };
    await storageObj.set(
      state,
      superjson.stringify(authState)
    );

    const platformEnvKey = `${Integrations.EnvPrefix(
      provider,
      platform
    )}_ID` as keyof Bindings;
    const baseEnvKey = `${Integrations.EnvPrefix(
      provider
    )}_ID` as keyof Bindings;

    const clientId = (env[platformEnvKey] ?? env[baseEnvKey]) as string;

    if (!clientId) {
      const logger = createLogger();
      logger.error("No client ID found for provider", {
        provider,
        platform,
        platform_env_key: platformEnvKey,
        base_env_key: baseEnvKey,
        available_auth_keys: Object.keys(env).filter((k) =>
          k.startsWith("AUTH_")
        ),
      });
      return null;
    }

    // For sign-in flows (no callback), use simplified Google OAuth params
    // For authorization flows (has callback), use full params from config
    const isSignInFlow = !callback && provider === "google";
    const additionalParams = isSignInFlow
      ? { prompt: "select_account" }
      : config.additionalParams;

    const params = new URLSearchParams({
      response_type: "code",
      client_id: clientId,
      redirect_uri: redirectUri,
      scope: allScopes.join(" "),
      state,
      code_challenge: codeChallenge,
      code_challenge_method: "S256",
      ...additionalParams,
    });

    const url = `${config.authUrl}?${params.toString()}`;

    return { url, clientId, state };
  }

  private static ALL_PLATFORMS: (undefined | "ios" | "android" | "desktop")[] =
    [undefined, "desktop", "ios", "android"];
  private static EnvPrefix(
    provider: AuthProvider,
    platform?: "ios" | "android" | "desktop"
  ) {
    return `AUTH_${provider.toUpperCase()}${
      platform ? `_${platform.toUpperCase()}` : ""
    }`;
  }

  private static SecretFromId(
    env: Bindings,
    provider: AuthProvider,
    id: string
  ) {
    const prefix = Integrations.ALL_PLATFORMS.map((platform) =>
      Integrations.EnvPrefix(provider, platform)
    ).find((p) => env[`${p}_ID` as keyof Bindings] === id);
    return prefix
      ? (env[`${prefix}_SECRET` as keyof Bindings] as string | undefined)
      : undefined;
  }

  /** Remove the Twisting tag from a note. Called by entrypoint for deferred tag removal. */
  async removeTagFromNote(noteId: string, actorId: string): Promise<void> {
    try {
      const pt = await this.db
        .selectFrom("twist_instance")
        .select("owner_id")
        .where("id", "=", this.twistInstanceId)
        .executeTakeFirst();

      if (pt?.owner_id) {
        await rpcUser(this.db, "update_note_tags", {
          user_id: pt.owner_id,
          p_note_id: noteId,
          p_actor_id: actorId,
          p_client_id: 0,
          p_tag_updates: { [Tag.Twist]: false },
        });
      }
    } catch (error) {
      console.warn("Failed to remove deferred Twisting tag from note", {
        note_id: noteId,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  /** Update a note's key for external dedup. Called by entrypoint when onNoteCreated returns a key. */
  async updateNoteKey(noteId: string, key: string): Promise<void> {
    await this.db
      .updateTable("note")
      .set({ key })
      .where("id", "=", noteId)
      .execute();
  }
}
