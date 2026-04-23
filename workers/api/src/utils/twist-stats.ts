import type { Kysely } from "kysely";

import type { DB } from "../db-types";
import type { Tracker } from "./tracker";

/**
 * PostHog person properties describing a user's active twists/connections.
 * Aggregate numbers (totals across users) are derivable in PostHog insights
 * from `active_connector_count` / `active_twist_count`, and per-connector or
 * per-twist breakdowns from the `active_connectors` / `active_twists` maps.
 */
type TwistStatsProperties = {
  active_connector_count: number;
  active_twist_count: number;
  // Map of twist package name → count of active instances. Example:
  //   { "google-calendar": 2, "slack": 1 }
  active_connectors: Record<string, number>;
  active_twists: Record<string, number>;
};

/** Compute a user's active twist/connector counts from `twist_instance`. */
export async function computeTwistStats(
  db: Kysely<DB>,
  userId: string,
): Promise<TwistStatsProperties> {
  const rows = await db
    .selectFrom("twist_instance as ti")
    .innerJoin("twist as t", "t.id", "ti.twist_id")
    .select(["t.name", "t.is_source"])
    .where("ti.owner_id", "=", userId)
    .where("ti.archived_at", "is", null)
    .where("ti.suspended_at", "is", null)
    .where("ti.draft", "=", false)
    .execute();

  const active_connectors: Record<string, number> = {};
  const active_twists: Record<string, number> = {};
  let active_connector_count = 0;
  let active_twist_count = 0;

  for (const row of rows) {
    const name = row.name;
    if (row.is_source) {
      active_connectors[name] = (active_connectors[name] ?? 0) + 1;
      active_connector_count++;
    } else {
      active_twists[name] = (active_twists[name] ?? 0) + 1;
      active_twist_count++;
    }
  }

  return {
    active_connector_count,
    active_twist_count,
    active_connectors,
    active_twists,
  };
}

/** Compute the user's stats and push them to PostHog as person properties. */
export async function syncUserTwistStats(
  db: Kysely<DB>,
  tracker: Tracker,
  userId: string,
): Promise<void> {
  const stats = await computeTwistStats(db, userId);
  tracker.setPersonProperties(userId, stats);
}
