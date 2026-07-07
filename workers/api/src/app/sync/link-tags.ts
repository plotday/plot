import type { Kysely } from "kysely";

import type { DB } from "../../db-types";
import { rpcUser } from "../../rpc";
import { truncateUuidForUpdatedBy } from "../../utils/uuid";

export type LinkTypeStatus = {
  status: string;
  label: string;
  tag?: number;
  done?: boolean;
  /**
   * When a link enters a status carrying `active`, the framework writes
   * thread_state.active=true for the link's affected user.
   */
  active?: boolean;
  /**
   * Marks the connector's "to-do" / active status — the target a done link
   * is flipped back to when a thread is brought back into the agenda
   * (see unarchiveDoneLinksOnThread). Not a thread_state flag.
   */
  todo?: boolean;
};

export type SharingModel = "thread" | "channel" | "message" | "none";

export type LinkTypeConfig = {
  type: string;
  statuses?: LinkTypeStatus[];
  sharingModel?: SharingModel;
};

/**
 * Propagate status tags from link statuses to the parent thread.
 * Called after upsert_link when a user changes a link's status.
 *
 * Uses union semantics: a tag is present if ANY link on the thread (from the same twist)
 * has a status that maps to that tag.
 *
 * Checks channel-level linkTypes first (from channel.link_types),
 * falling back to twist-level linkTypes (from twist.permissions._providers[].linkTypes).
 */
export async function propagateLinkStatusTagsFromDb(
  db: Kysely<DB>,
  link: { id: string; thread_id: string | null; created_by: string | null; type: string | null; status: string | null }
): Promise<void> {
  if (!link.thread_id || !link.created_by) return;

  // Try channel-level linkTypes first
  let allLinkTypes: LinkTypeConfig[] = await getChannelLinkTypes(db, link.id, link.created_by);

  // Fall back to twist-level linkTypes
  if (allLinkTypes.length === 0) {
    const twistRow = await db
      .selectFrom("twist_instance")
      .innerJoin("twist", "twist.id", "twist_instance.twist_id")
      .select("twist.permissions")
      .where("twist_instance.id", "=", link.created_by)
      .executeTakeFirst();

    if (!twistRow?.permissions) return;

    const permissions = twistRow.permissions as any;
    const providers = permissions._providers;
    if (!Array.isArray(providers)) return;

    allLinkTypes = providers.flatMap(
      (p: any) => (p.linkTypes ?? []) as LinkTypeConfig[]
    );
  }
  if (allLinkTypes.length === 0) return;

  // Collect all possible tags from status definitions
  const allPossibleTags = new Set<number>();
  for (const lt of allLinkTypes) {
    for (const s of lt.statuses ?? []) {
      if (s.tag !== undefined) allPossibleTags.add(s.tag);
    }
  }
  if (allPossibleTags.size === 0) return;

  // Query all links on this thread from this twist
  const siblingLinks = await db
    .selectFrom("link")
    .select(["type", "status"])
    .where("thread_id", "=", link.thread_id)
    .where("created_by", "=", link.created_by)
    .execute();

  // Compute union of contributed tags
  const contributedTags = new Set<number>();
  for (const sibling of siblingLinks) {
    if (!sibling.type || !sibling.status) continue;
    const typeConfig = allLinkTypes.find((lt) => lt.type === sibling.type);
    const statusDef = typeConfig?.statuses?.find((s) => s.status === sibling.status);
    if (statusDef?.tag !== undefined) contributedTags.add(statusDef.tag);
  }

  const updatedBy = truncateUuidForUpdatedBy(link.created_by);

  // Insert tags that should be present
  for (const tagId of contributedTags) {
    await db
      .insertInto("thread_tag")
      .values({
        thread_id: link.thread_id,
        occurrence: null,
        tag_id: tagId,
        actor_id: link.created_by,
        updated_by: updatedBy,
        sync_depth: 1,
      })
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

  // Remove tags that are no longer contributed
  for (const tagId of allPossibleTags) {
    if (!contributedTags.has(tagId)) {
      await db
        .updateTable("thread_tag")
        .set({ archived_at: new Date(), updated_by: updatedBy, sync_depth: 1 })
        .where("thread_id", "=", link.thread_id)
        .where("actor_id", "=", link.created_by)
        .where("tag_id", "=", tagId)
        .where("archived_at", "is", null)
        .execute();
    }
  }
}

/**
 * Match a link's `channel_id` against a connection's channel rows, tolerating
 * the composite-connector namespace prefix.
 *
 * Composite connectors (e.g. the Google "Gmail & Calendar" connector) register
 * their channels with a namespaced id `"<product>:<rawId>"` (`mail:INBOX`,
 * `calendar:<calId>`, `tasks:<listId>`) but save links with the BARE `rawId`
 * (`INBOX`, `<calId>`, `<listId>`). A plain equality lookup therefore misses
 * every composite link and falls through to the (empty) twist-level linkTypes,
 * so no channel-level config is ever resolved for them.
 *
 * Resolution: exact match wins; otherwise fall back to a row whose id equals
 * `"<anything>:<channelId>"`, splitting on the FIRST ':' to mirror
 * `public/connectors/google/src/product-channel.ts` `parse()`.
 */
export function matchChannelByLinkId<T extends { channel_id: string }>(
  channels: T[],
  linkChannelId: string
): T | undefined {
  const exact = channels.find((c) => c.channel_id === linkChannelId);
  if (exact) return exact;
  return channels.find((c) => {
    const idx = c.channel_id.indexOf(":");
    return idx >= 0 && c.channel_id.slice(idx + 1) === linkChannelId;
  });
}

/**
 * Look up channel-level linkTypes for a link.
 * Queries the link's channel_id, then looks up link_types from channel.
 */
export async function getChannelLinkTypes(
  db: Kysely<DB>,
  linkId: string,
  createdBy: string
): Promise<LinkTypeConfig[]> {
  const linkRow = await db
    .selectFrom("link")
    .select("channel_id")
    .where("id", "=", linkId)
    .executeTakeFirst();
  if (!linkRow?.channel_id) return [];

  // Fetch the connection's channels (a small, bounded set — one row per
  // enabled resource) and match prefix-tolerantly: composite links carry the
  // bare rawId while the channel row is stored namespaced. See
  // matchChannelByLinkId.
  const channels = await db
    .selectFrom("channel")
    .select(["channel_id", "link_types"])
    .where("twist_instance_id", "=", createdBy)
    .execute();
  const channel = matchChannelByLinkId(channels, linkRow.channel_id);
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
 * Load channel-level linkTypes using a known external channelId and
 * twistInstanceId, without requiring a pre-existing link row. Used by the
 * pre-creation reconciliation path in `createLink` where the link hasn't been
 * written yet.
 */
export async function getLinkTypesForChannelId(
  db: Kysely<DB>,
  channelId: string,
  twistInstanceId: string
): Promise<LinkTypeConfig[]> {
  const channel = await db
    .selectFrom("channel")
    .select("link_types")
    .where("twist_instance_id", "=", twistInstanceId)
    .where("channel_id", "=", channelId)
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
 * Resolve the sharingModel for a given (channelId, linkType, twistInstanceId)
 * triple. Channel-level linkTypes take precedence; falls back to twist-level
 * permissions._providers[].linkTypes.
 *
 * Returns undefined when neither channel nor twist declares a sharingModel for
 * this type.
 */
export async function getSharingModelForChannel(
  db: Kysely<DB>,
  channelId: string | null | undefined,
  linkType: string | null | undefined,
  twistInstanceId: string
): Promise<"thread" | "channel" | "message" | "none" | undefined> {
  if (!linkType) return undefined;

  let allLinkTypes: LinkTypeConfig[] = [];

  if (channelId) {
    allLinkTypes = await getLinkTypesForChannelId(db, channelId, twistInstanceId);
  }

  if (allLinkTypes.length === 0) {
    const twistRow = await db
      .selectFrom("twist_instance")
      .innerJoin("twist", "twist.id", "twist_instance.twist_id")
      .select("twist.permissions")
      .where("twist_instance.id", "=", twistInstanceId)
      .executeTakeFirst();
    if (!twistRow?.permissions) return undefined;
    const permissions = twistRow.permissions as any;
    const providers = permissions._providers;
    if (!Array.isArray(providers)) return undefined;
    allLinkTypes = providers.flatMap(
      (p: any) => (p.linkTypes ?? []) as LinkTypeConfig[]
    );
  }

  const typeConfig = allLinkTypes.find((lt) => lt.type === linkType);
  return typeConfig?.sharingModel;
}

/**
 * Load the full linkTypes config for a link — channel-level first, twist-level fallback.
 */
export async function getLinkTypesForLink(
  db: Kysely<DB>,
  linkId: string,
  createdBy: string
): Promise<LinkTypeConfig[]> {
  let allLinkTypes = await getChannelLinkTypes(db, linkId, createdBy);
  if (allLinkTypes.length === 0) {
    const twistRow = await db
      .selectFrom("twist_instance")
      .innerJoin("twist", "twist.id", "twist_instance.twist_id")
      .select("twist.permissions")
      .where("twist_instance.id", "=", createdBy)
      .executeTakeFirst();
    if (!twistRow?.permissions) return [];
    const permissions = twistRow.permissions as any;
    const providers = permissions._providers;
    if (!Array.isArray(providers)) return [];
    allLinkTypes = providers.flatMap(
      (p: any) => (p.linkTypes ?? []) as LinkTypeConfig[]
    );
  }
  return allLinkTypes;
}

/**
 * Find any links on a thread whose current status is marked done, and flip
 * them back to the first non-done status for their type. Then re-propagates
 * thread tags so Tag.Done (or any other done-status tag) is cleared.
 *
 * Called when a thread is brought back into the agenda (e.g. user adds it
 * to to-do) so the link widget and thread tags reflect the active state.
 */
export async function unarchiveDoneLinksOnThread(
  db: Kysely<DB>,
  threadId: string
): Promise<void> {
  const links = await db
    .selectFrom("link")
    .select(["id", "created_by", "type", "status"])
    .where("thread_id", "=", threadId)
    .where("created_by", "is not", null)
    .execute();

  let changed = false;
  for (const link of links) {
    if (!link.type || !link.status || !link.created_by) continue;

    const linkTypes = await getLinkTypesForLink(db, link.id, link.created_by);
    const typeConfig = linkTypes.find((lt) => lt.type === link.type);
    if (!typeConfig?.statuses) continue;

    const currentStatus = typeConfig.statuses.find((s) => s.status === link.status);
    if (currentStatus?.done !== true) continue;

    // Prefer a status explicitly marked `todo: true` by the connector (e.g.
    // Gmail's "starred", Linear's "unstarted"). Fall back to the first
    // non-done status if the connector didn't mark one.
    const nonDoneStatus =
      typeConfig.statuses.find((s) => s.todo === true) ??
      typeConfig.statuses.find((s) => s.done !== true);
    if (!nonDoneStatus) continue;

    await db
      .updateTable("link")
      .set({ status: nonDoneStatus.status, updated_at: new Date() })
      .where("id", "=", link.id)
      .execute();

    await propagateLinkStatusTagsFromDb(db, {
      id: link.id,
      thread_id: threadId,
      created_by: link.created_by,
      type: link.type,
      status: nonDoneStatus.status,
    });
    changed = true;
  }

  if (!changed) return;
}

/**
 * Check if a link's current status represents completion ("done").
 * Checks channel-level linkTypes first, falling back to twist-level.
 */
export async function isLinkStatusDone(
  db: Kysely<DB>,
  link: { id: string; created_by: string | null; type: string | null; status: string | null }
): Promise<boolean> {
  if (!link.type || !link.status || !link.created_by) return false;

  // Try channel-level linkTypes first
  let allLinkTypes: LinkTypeConfig[] = await getChannelLinkTypes(db, link.id, link.created_by);

  // Fall back to twist-level linkTypes
  if (allLinkTypes.length === 0) {
    const twistRow = await db
      .selectFrom("twist_instance")
      .innerJoin("twist", "twist.id", "twist_instance.twist_id")
      .select("twist.permissions")
      .where("twist_instance.id", "=", link.created_by)
      .executeTakeFirst();

    if (!twistRow?.permissions) return false;

    const permissions = twistRow.permissions as any;
    const providers = permissions._providers;
    if (!Array.isArray(providers)) return false;

    allLinkTypes = providers.flatMap(
      (p: any) => (p.linkTypes ?? []) as LinkTypeConfig[]
    );
  }

  const typeConfig = allLinkTypes.find((lt) => lt.type === link.type);
  if (!typeConfig?.statuses) return false;
  const statusDef = typeConfig.statuses.find((s) => s.status === link.status);
  return statusDef?.done === true;
}

/**
 * Resolve the LinkStatus definition for a link's current (type, status) pair.
 * Returns null when the link's type isn't declared by the twist or the status
 * isn't enumerated.
 */
async function getStatusDef(
  db: Kysely<DB>,
  link: { id: string; created_by: string | null; type: string | null; status: string | null }
): Promise<LinkTypeStatus | null> {
  if (!link.type || !link.status || !link.created_by) return null;

  let allLinkTypes: LinkTypeConfig[] = await getChannelLinkTypes(db, link.id, link.created_by);
  if (allLinkTypes.length === 0) {
    const twistRow = await db
      .selectFrom("twist_instance")
      .innerJoin("twist", "twist.id", "twist_instance.twist_id")
      .select("twist.permissions")
      .where("twist_instance.id", "=", link.created_by)
      .executeTakeFirst();
    if (!twistRow?.permissions) return null;
    const providers = (twistRow.permissions as any)._providers;
    if (!Array.isArray(providers)) return null;
    allLinkTypes = providers.flatMap((p: any) => (p.linkTypes ?? []) as LinkTypeConfig[]);
  }

  const typeConfig = allLinkTypes.find((lt) => lt.type === link.type);
  return typeConfig?.statuses?.find((s) => s.status === link.status) ?? null;
}

/**
 * Propagate a link's status `active` flag to thread_state for the affected
 * user.
 *
 *  - Assignee-bearing links (Linear, Todoist, etc.): the assignee's user.
 *  - Messaging links (Gmail star, Slack later): the twist_instance owner
 *    (per-user connection — the link's creator).
 *
 * Done-status links are a no-op for active: completion is signaled by the
 * absence of the flag, not by writing FALSE (which would clobber a user's
 * own manual flag). To clear, the connector emits a status that does NOT
 * carry the flag, and the existing schedule cleanup paths take over.
 *
 * Never throws.
 */
export async function propagateLinkStateFlagsFromDb(
  db: Kysely<DB>,
  link: {
    id: string;
    thread_id: string | null;
    created_by: string | null;
    type: string | null;
    status: string | null;
    assignee_id: string | null;
  }
): Promise<void> {
  if (!link.thread_id || !link.created_by) return;

  const statusDef = await getStatusDef(db, link);
  if (!statusDef) return;

  // Resolve the affected user. Prefer the assignee (tracker-style links);
  // fall back to the twist_instance owner (messaging connections).
  let userId: string | null = null;
  if (link.assignee_id) {
    const contact = await db
      .selectFrom("contact")
      .select("user_id")
      .where("id", "=", link.assignee_id)
      .executeTakeFirst();
    userId = contact?.user_id ?? null;
  }
  if (!userId) {
    const owner = await db
      .selectFrom("twist_instance")
      .select("owner_id")
      .where("id", "=", link.created_by)
      .executeTakeFirst();
    userId = owner?.owner_id ?? null;
  }
  if (!userId) return;

  const wantsActive = statusDef.active === true;
  if (!wantsActive) return;

  try {
    await rpcUser(db, "upsert_thread_state", {
      user_id: userId,
      p_thread_id: link.thread_id,
      p_active: wantsActive,
      p_urgent: false,
      p_importance: 50,
      p_set_active: wantsActive,
      p_set_urgent: false,
      p_set_importance: false,
    });
  } catch (error) {
    console.error("[link-state] Failed to propagate link state flags:", error);
  }
}
