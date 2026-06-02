/**
 * Allowlist of `twist_package_id` values that the deploy pipeline stamps
 * as premium (`twist.premium = true`).
 *
 * Premium connectors have a real per-connection cost (e.g. Unipile-backed
 * integrations) and are metered separately from the regular pool — see
 * `PLAN_LIMITS[plan].premium` and `checkChannelConnectionLimit()` in
 * `../utils/limits.ts`.
 *
 * This lives in the private API worker, not in the public `@plotday/twister`
 * package or the `Connector` base class. Reasons:
 *
 * 1. Premium-ness is a billing/policy concern, not a connector
 *    implementation detail — the connector itself behaves identically
 *    whether or not we charge differently for it.
 * 2. Public connector authors must not be able to claim premium status.
 *    Keeping the truth server-side, in a private file, makes that
 *    enforceable by construction.
 * 3. Adding a new premium connector is a deliberate, auditable change:
 *    one new line here, reviewed in the private repo.
 *
 * To add a connector: paste its `plotTwistId` (from the connector's
 * `package.json`) into this set. After redeploying the API and the
 * connector, the next deploy of that connector stamps `twist.premium = true`
 * on its row, and the existing enforcement / UI machinery picks it up.
 */
export const PREMIUM_TWIST_PACKAGE_IDS: ReadonlySet<string> = new Set([
  // @plotday/connector-linkedin — Unipile-backed messaging.
  "4e6a959d-ebe2-4a85-bd06-ec46fbac204a",
]);

export function isPremiumTwistPackage(twistPackageId: string): boolean {
  return PREMIUM_TWIST_PACKAGE_IDS.has(twistPackageId);
}
