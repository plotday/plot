import type { Kysely } from "kysely";

import type { DB } from "../../db-types";
import { truncateUuidForUpdatedBy } from "../../utils/uuid";

type LinkTypeStatus = {
  status: string;
  label: string;
  tag?: number;
};

type LinkTypeConfig = {
  type: string;
  statuses?: LinkTypeStatus[];
};

/**
 * Propagate status tags from link statuses to the parent thread.
 * Called after upsert_link when a user changes a link's status.
 *
 * Uses union semantics: a tag is present if ANY link on the thread (from the same twist)
 * has a status that maps to that tag.
 *
 * Checks channel-level linkTypes first (from source_channel.link_types),
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
      .selectFrom("priority_twist")
      .innerJoin("twist", "twist.id", "priority_twist.twist_id")
      .select("twist.permissions")
      .where("priority_twist.id", "=", link.created_by)
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
 * Look up channel-level linkTypes for a link.
 * Queries the link's channel_id, then looks up link_types from source_channel.
 */
async function getChannelLinkTypes(
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

  const channel = await db
    .selectFrom("source_channel")
    .select("link_types")
    .where("priority_twist_id", "=", createdBy)
    .where("channel_id", "=", linkRow.channel_id)
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
