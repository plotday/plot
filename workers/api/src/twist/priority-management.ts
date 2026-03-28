import { type Kysely, sql } from "kysely";

import type { DB } from "../db-types";
import { rpc } from "../rpc";

/** Check if an error is a PostgreSQL unique constraint violation (code 23505) */
function isDuplicateKeyError(error: unknown): boolean {
  return (error as any)?.code === "23505";
}

/**
 * Gets or creates the "Plot" priority for a user.
 * This priority is created as a direct child of the user's root priority
 * and marked with key = '@plot' for easy identification.
 */
export async function getOrCreatePlotPriority(
  userId: string,
  db: Kysely<DB>
): Promise<string> {
  // First get the user's root priority to scope the key lookup
  const rootResult = await db
    .selectFrom("priority_user")
    .innerJoin("priority", "priority.id", "priority_user.priority_id")
    .select(["priority_user.priority_id", "priority.path"])
    .where("priority_user.user_id", "=", userId)
    .where("priority_user.personal", "=", true)
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
  // Generate child path
  // rpc() unwraps scalar results, so we get the path string directly
  const path = await rpc(db, "generate_path", {
    parent: rootPath,
  });

  // Create the Plot priority — handle race condition where a concurrent
  // request creates it between our SELECT and INSERT
  try {
    const createResult = await db
      .insertInto("priority")
      .values({
        created_by: userId,
        title: "Plot",
        path: path as string,
        updated_by: 0,
        key: "@plot",
        color: 7, // Resolution color (blue-gray)
      })
      .returning(["id"])
      .executeTakeFirstOrThrow();

    return createResult.id;
  } catch (error) {
    if (isDuplicateKeyError(error)) {
      // Another concurrent request created it — re-SELECT
      const retryResult = await db
        .selectFrom("priority")
        .select(["id"])
        .where("key", "=", "@plot")
        .where(sql<boolean>`path <@ ${rootPathPart}::ltree`)
        .executeTakeFirstOrThrow();
      return retryResult.id;
    }
    throw error;
  }
}

/**
 * Gets or creates the "Twist Development" priority for a user.
 * This priority is created as a direct child of the Plot priority
 * and marked with key = '@plot.twist-dev' for easy identification.
 */
export async function getOrCreateTwistDevelopmentPriority(
  userId: string,
  db: Kysely<DB>
): Promise<string> {
  // First ensure the Plot priority exists and get its path
  const plotPriorityId = await getOrCreatePlotPriority(userId, db);

  // Get the Plot priority path to scope the key lookup
  const plotResult = await db
    .selectFrom("priority")
    .select(["path"])
    .where("id", "=", plotPriorityId)
    .executeTakeFirstOrThrow();

  const plotPath = plotResult.path as string;
  const rootPathPart = plotPath.split(".")[0];

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

  // Not found, need to create it

  // Generate child path
  // rpc() unwraps scalar results, so we get the path string directly
  const path = await rpc(db, "generate_path", {
    parent: plotResult.path,
  });

  // Create the Twist Development priority — handle race condition
  try {
    const createResult = await db
      .insertInto("priority")
      .values({
        created_by: userId,
        title: "Twist Development",
        path: path as string,
        updated_by: 0,
        key: "@plot.twist-dev",
      })
      .returning(["id"])
      .executeTakeFirstOrThrow();

    return createResult.id;
  } catch (error) {
    if (isDuplicateKeyError(error)) {
      const retryResult = await db
        .selectFrom("priority")
        .select(["id"])
        .where("key", "=", "@plot.twist-dev")
        .where(sql<boolean>`path <@ ${rootPathPart}::ltree`)
        .executeTakeFirstOrThrow();
      return retryResult.id;
    }
    throw error;
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
  // Retry once on duplicate key — a concurrent deploy may have created the
  // priority between our SELECT and INSERT. On retry the SELECT will find it.
  for (let attempt = 0; attempt < 2; attempt++) {
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

    // Not found, need to create new priority and twist_admin entry
    // First ensure Twist Development priority exists
    const twistDevPriorityId = await getOrCreateTwistDevelopmentPriority(
      userId,
      db
    );

    // Get the Twist Development priority path
    const twistDevResult = await db
      .selectFrom("priority")
      .select(["path", "created_by"])
      .where("id", "=", twistDevPriorityId)
      .executeTakeFirstOrThrow();

    // Generate child path
    // rpc() unwraps scalar results, so we get the path string directly
    const path = await rpc(db, "generate_path", {
      parent: twistDevResult.path,
    });

    // Create the twist-specific priority — handle race condition
    const priorityTitle = isPersonal ? `${twistName} (Personal)` : twistName;
    let priorityId: string;
    try {
      const createPriorityResult = await db
        .insertInto("priority")
        .values({
          created_by: twistDevResult.created_by,
          title: priorityTitle,
          path: path as string,
          updated_by: 0,
        })
        .returning(["id"])
        .executeTakeFirstOrThrow();
      priorityId = createPriorityResult.id;
    } catch (error) {
      if (isDuplicateKeyError(error) && attempt === 0) {
        // Concurrent request created a priority — retry from the top
        // so the SELECT finds the twist_admin entry
        continue;
      }
      throw error;
    }

    // Create or update twist_admin entry
    if (existingResult) {
      // twist_admin exists but priority_id was null - update it
      const updateResult = await db
        .updateTable("twist_admin")
        .set({ priority_id: priorityId })
        .where("id", "=", existingResult.id)
        .returning(["id"])
        .executeTakeFirstOrThrow();

      return {
        priorityId,
        twistAdminId: Number(updateResult.id),
        isNew: true,
      };
    } else {
      // Create new twist_admin entry
      const twistAdminData: {
        twist_package_id: string;
        priority_id: string;
        user_id?: string;
        publisher_id?: number | bigint | string;
      } = {
        twist_package_id: twistPackageId,
        priority_id: priorityId,
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

      try {
        const createAdminResult = await db
          .insertInto("twist_admin")
          .values(twistAdminData)
          .returning(["id"])
          .executeTakeFirstOrThrow();

        return {
          priorityId,
          twistAdminId: Number(createAdminResult.id),
          isNew: true,
        };
      } catch (error) {
        if (isDuplicateKeyError(error) && attempt === 0) {
          // Concurrent request created the twist_admin — retry from the top
          continue;
        }
        throw error;
      }
    }
  }

  // Should not be reached — retry loop always returns or throws
  throw new Error("Failed to get or create twist priority after retry");
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
