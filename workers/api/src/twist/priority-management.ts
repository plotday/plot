import { type Kysely, sql } from "kysely";

import type { DB } from "../db-types";
import { generatePath } from "../utils/path";

/**
 * Gets or creates the "Plot" priority for a user.
 * This priority is created as a direct child of the user's root priority
 * and marked with key = '@plot' for easy identification.
 */
export async function getOrCreatePlotPriority(
  userId: string,
  db: Kysely<DB>
): Promise<string> {
  // Find the user's root priority (depth-1 path)
  const rootResult = await db
    .selectFrom("priority")
    .select(["id", "path"])
    .where("user_id", "=", userId)
    .where(sql<boolean>`nlevel(path) = 1`)
    .where("archived_at", "is", null)
    .executeTakeFirstOrThrow();

  const rootPath = rootResult.path as string;
  const rootPathPart = rootPath.split(".")[0];

  // Try to find existing Plot priority by key, scoped to root
  const existingResult = await db
    .selectFrom("priority")
    .select(["id"])
    .where("key", "=", "@plot")
    .where(sql<boolean>`path <@ ${rootPathPart}::ltree`)
    .executeTakeFirst();

  if (existingResult) {
    return existingResult.id;
  }

  // Not found, need to create it
  // Generate child path using no-cache DB to avoid Hyperdrive returning
  // the same cached random path to concurrent requests
  const path = generatePath(rootPath);

  // Create the Plot priority — handle race condition where a concurrent
  // request creates it between our SELECT and INSERT
  try {
    const createResult = await db
      .insertInto("priority")
      .values({
        created_by: userId,
        user_id: userId,
        title: "Plot",
        path: path as string,
        updated_by: 0,
        key: "@plot",
        color: 7, // Resolution color (blue-gray)
      })
      .returning(["id"])
      .executeTakeFirstOrThrow();

    return createResult.id;
  } catch (insertError) {
    // Race condition: another request may have created it — re-SELECT
    const retryResult = await db
      .selectFrom("priority")
      .select(["id"])
      .where("key", "=", "@plot")
      .where(sql<boolean>`path <@ ${rootPathPart}::ltree`)
      .executeTakeFirst();
    if (retryResult) {
      return retryResult.id;
    }
    throw insertError;
  }
}

/**
 * Gets or creates the "Twist Development" priority for a user.
 * This priority is created as a top-level child of the user's root priority
 * and marked with key = '@plot.twist-dev' for easy identification.
 */
export async function getOrCreateTwistDevelopmentPriority(
  userId: string,
  db: Kysely<DB>
): Promise<string> {
  // Get user's root priority path
  const rootResult = await db
    .selectFrom("priority")
    .select("path")
    .where("user_id", "=", userId)
    .where(sql<boolean>`nlevel(path) = 1`)
    .where("archived_at", "is", null)
    .executeTakeFirst();

  if (!rootResult) {
    throw new Error("User has no root priority");
  }

  const rootPath = rootResult.path as string;
  const rootPathPart = rootPath.split(".")[0];

  // Try to find existing Twist Development priority by key, scoped to root
  const existingResult = await db
    .selectFrom("priority")
    .select(["id"])
    .where("key", "=", "@plot.twist-dev")
    .where(sql<boolean>`path <@ ${rootPathPart}::ltree`)
    .executeTakeFirst();

  if (existingResult) {
    return existingResult.id;
  }

  // Generate child path under user root
  const path = generatePath(rootPath);

  // Create the Twist Development priority — handle race condition. In
  // the per-user priority model the old inherit_members / viewer dance
  // is gone; the priority is simply owned by the user.
  try {
    const createResult = await db
      .insertInto("priority")
      .values({
        created_by: userId,
        user_id: userId,
        title: "Twist Development",
        path: path as string,
        updated_by: 0,
        key: "@plot.twist-dev",
      })
      .returning(["id"])
      .executeTakeFirstOrThrow();

    return createResult.id;
  } catch (insertError) {
    const retryResult = await db
      .selectFrom("priority")
      .select(["id"])
      .where("key", "=", "@plot.twist-dev")
      .where(sql<boolean>`path <@ ${rootPathPart}::ltree`)
      .executeTakeFirst();
    if (retryResult) {
      return retryResult.id;
    }
    throw insertError;
  }
}

/**
 * Gets or creates a priority for a specific twist deployment.
 * Uses twist_admin to find existing priorities by twist_package_id and isPersonal.
 * If not found, creates a new priority as a child of "Twist Development" and
 * creates a twist_admin entry for future lookups.
 */
export async function getOrCreateTwistPriority(
  userId: string,
  twistPackageId: string,
  twistName: string,
  isPersonal: boolean,
  db: Kysely<DB>,
  publisherId?: number | null
): Promise<{ priorityId: string; twistAdminId: number; isNew: boolean }> {
  // Query twist_admin to see if this twist already has a priority
  let query = db
    .selectFrom("twist_admin")
    .select(["id", "priority_id"])
    .where("twist_package_id", "=", twistPackageId);

  if (isPersonal) {
    query = query.where("user_id", "=", userId);
  } else {
    query = query.where("user_id", "is", null);
  }

  const existingResult = await query.executeTakeFirst();

  if (existingResult?.priority_id) {
    return {
      priorityId: existingResult.priority_id,
      twistAdminId: Number(existingResult.id),
      isNew: false,
    };
  }

  // Not found, need to ensure Twist Development priority exists and use it
  const twistDevPriorityId = await getOrCreateTwistDevelopmentPriority(
    userId,
    db
  );

  let twistAdminId: number;

  if (existingResult) {
    // twist_admin exists but priority_id was null - update it
    const updateResult = await db
      .updateTable("twist_admin")
      .set({ priority_id: twistDevPriorityId })
      .where("id", "=", existingResult.id)
      .returning(["id"])
      .executeTakeFirstOrThrow();
    twistAdminId = Number(updateResult.id);
  } else {
    // Create new twist_admin entry
    const twistAdminData: {
      twist_package_id: string;
      priority_id: string;
      user_id?: string;
      publisher_id?: number | bigint | string;
    } = {
      twist_package_id: twistPackageId,
      priority_id: twistDevPriorityId,
    };

    if (isPersonal) {
      twistAdminData.user_id = userId;
    } else {
      // For non-personal, we need a publisher_id to satisfy the ownership check constraint
      if (publisherId === undefined || publisherId === null) {
        throw new Error(
          "Publisher ID is required for non-personal twist deployments"
        );
      }
      twistAdminData.publisher_id = publisherId;
    }

    const createAdminResult = await db
      .insertInto("twist_admin")
      .values(twistAdminData)
      .returning(["id"])
      .executeTakeFirstOrThrow();
    twistAdminId = Number(createAdminResult.id);
  }

  // If this is a personal deployment, ensure there's a priority rule linking its
  // auto-maintained topic to the Twist Development priority. The topic is
  // created by the auto_maintain_twist_admin_topic trigger on twist_admin insert.
  if (isPersonal) {
    const topic = await db
      .selectFrom("topic")
      .select("id")
      .where("auto_twist_admin_id", "=", String(twistAdminId))
      .executeTakeFirst();

    if (topic) {
      await db
        .insertInto("priority_rule")
        .values({
          user_id: userId,
          priority_id: twistDevPriorityId,
          type: "contact_topics",
          criteria: JSON.stringify({ topics: [topic.id] }),
        })
        .onConflict((oc) => oc.doNothing())
        .execute();
    }
  }

  return {
    priorityId: twistDevPriorityId,
    twistAdminId,
    isNew: true,
  };
}

/**
 * Gets all publishers that the user has access to.
 * Returns publishers from twist_admin entries where the user has access to the priority.
 */
export async function getAccessiblePublishers(
  userId: string,
  db: Kysely<DB>
): Promise<Array<{ id: number; name: string; email: string | null; url: string | null }>> {
  // Get publishers from twist_admin where priority_id is accessible
  // We query twist_admin entries that have a publisher and priority
  const results = await db
    .selectFrom("twist_admin")
    .innerJoin("publisher", "publisher.id", "twist_admin.publisher_id")
    .select([
      "publisher.id",
      "publisher.name",
      "publisher.email",
      "publisher.url",
    ])
    .where("twist_admin.publisher_id", "is not", null)
    .where("twist_admin.priority_id", "is not", null)
    .execute();

  // Filter to unique publishers
  const publishers = new Map<
    number,
    { id: number; name: string; email: string | null; url: string | null }
  >();

  for (const row of results) {
    const id = Number(row.id);
    if (!publishers.has(id)) {
      publishers.set(id, {
        id,
        name: row.name,
        email: row.email,
        url: row.url,
      });
    }
  }

  return Array.from(publishers.values());
}

/**
 * Creates a new publisher record.
 */
export async function createPublisher(
  name: string,
  url: string | null,
  db: Kysely<DB>
): Promise<{ id: number; name: string; email: string | null; url: string | null }> {
  const result = await db
    .insertInto("publisher")
    .values({
      name,
      url,
    })
    .returning(["id", "name", "email", "url"])
    .executeTakeFirstOrThrow();

  return {
    id: Number(result.id),
    name: result.name,
    email: result.email,
    url: result.url,
  };
}
