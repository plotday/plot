import { type Kysely, sql } from "kysely";

import type { DB } from "../db-types";

/**
 * Gets all publishers that the user has access to — i.e. publishers whose
 * auto-maintained publisher topic lists one of the user's linked contacts as
 * a member.
 */
export async function getAccessiblePublishers(
  userId: string,
  db: Kysely<DB>
): Promise<Array<{ id: number; name: string; email: string | null; url: string | null }>> {
  const results = await db
    .selectFrom("publisher")
    .innerJoin("topic", (join) =>
      join
        .onRef("topic.auto_publisher_id", "=", "publisher.id")
        .on("topic.auto_maintained", "=", true)
    )
    .innerJoin("topic_member", "topic_member.topic_id", "topic.id")
    .innerJoin("user_contact", (join) =>
      join
        .onRef("user_contact.contact_id", "=", "topic_member.contact_id")
        .on("user_contact.linked", "=", true)
        .on("user_contact.archived_at", "is", null)
    )
    .select([
      "publisher.id",
      "publisher.name",
      "publisher.email",
      "publisher.url",
    ])
    .where("user_contact.user_id", "=", userId)
    .distinct()
    .execute();

  return results.map((row) => ({
    id: Number(row.id),
    name: row.name,
    email: row.email,
    url: row.url,
  }));
}

/**
 * Creates or returns the publisher with the given name (case-insensitive).
 * Uses ON CONFLICT on the lower(name) unique index so concurrent CLI flows
 * can't create duplicates.
 */
export async function createPublisher(
  name: string,
  url: string | null,
  createdBy: string,
  db: Kysely<DB>
): Promise<{ id: number; name: string; email: string | null; url: string | null }> {
  const result = await db
    .insertInto("publisher")
    .values({
      name,
      url,
      created_by: createdBy,
    })
    .onConflict((oc) =>
      oc
        .expression(sql`(lower(name))`)
        .doUpdateSet({ name: sql`excluded.name` })
    )
    .returning(["id", "name", "email", "url"])
    .executeTakeFirstOrThrow();

  return {
    id: Number(result.id),
    name: result.name,
    email: result.email,
    url: result.url,
  };
}
