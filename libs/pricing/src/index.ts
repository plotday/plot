/**
 * Single source of truth for Plot pricing numbers. Consumed by the API worker
 * (workers/api) and the marketing site (apps/site). Flutter (Dart) cannot import
 * this; it derives capacity from server responses and reads the two web add-on
 * prices from the /upgrade/usage payload. Pure constants only — no logic/deps.
 */

/** Per-plan included capacity. Team has no fixed twistCapacity/connections — it
 *  uses an interchangeable slot pool of TEAM_SLOTS_PER_GROUP × purchased blocks. */
export const PLAN = {
  free: { connections: 2, twistCapacity: 1, syncHistoryDays: 7 },
  pro: { connections: Infinity, twistCapacity: 3, syncHistoryDays: 365 },
  team: { syncHistoryDays: 365 },
} as const;

/** Interchangeable Team slots granted per purchased 50-block (connection_group_quantity). */
export const TEAM_SLOTS_PER_GROUP = 50;

/** Twist automations granted per twist add-on pack. */
export const TWIST_ADDON_BLOCK_SIZE = 5;

/** Connection add-on price, USD/month (web/Stripe). */
export const CONNECTION_ADDON_PRICE = 5;

/** Twist add-on price, USD/month (web/Stripe). */
export const TWIST_ADDON_PRICE = 10;

/** Plan prices, USD/month. */
export const PLAN_PRICES = {
  pro: { monthly: 25, annual: 20 },
  team: { monthly: 124, annual: 99 },
} as const;
