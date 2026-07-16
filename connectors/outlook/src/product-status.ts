import type { Product } from "./products";

/**
 * Per-product enablement, surfaced to the client (frozen contract §4.2) and
 * used to decide which products' sync runs. The reason explains a disabled
 * product so the status UI can show the right affordance (re-auth vs. toggle).
 */
export type ProductStatusReason =
  | "granted" // scope granted and actively syncing
  | "scope-missing" // required scope not granted → needs re-auth
  | "locally-off" // scope granted but the user turned the product off
  | "no-channels"; // scope granted, on, but no channel enabled

export type ProductStatus = {
  key: string;
  enabled: boolean;
  reason: ProductStatusReason;
};

/**
 * Inputs the connector knows at status time. Kept explicit (not read from
 * `this`) so this is a pure, unit-testable function — the runtime wiring that
 * gathers granted scopes (KV) and channel/local-off state lives elsewhere.
 */
export type ProductStatusInputs = {
  /** OAuth scopes actually granted for this connection (from the token / KV). */
  grantedScopes: string[];
  /** Count of currently-enabled channels per product key. */
  enabledChannelCount: Record<string, number>;
  /** Products the user explicitly turned off (mainly channelless ones). */
  locallyOff: Record<string, boolean>;
};

/**
 * Computes per-product status from granted scopes + channel/local-off state.
 *
 * enabled(product) = requiredScopes ⊆ grantedScopes
 *                    AND NOT locally turned off
 *                    AND (channelless OR ≥1 enabled channel)
 *
 * (Spec §2.4 / §2.6. The client never sees raw scopes — only this derived
 * enablement.)
 */
export function computeProductStatus(
  products: Product[],
  inputs: ProductStatusInputs,
): ProductStatus[] {
  const granted = new Set(inputs.grantedScopes);
  return products.map((product) => {
    const hasAllScopes = product.requiredScopes.every((s) => granted.has(s));
    if (!hasAllScopes) {
      return { key: product.key, enabled: false, reason: "scope-missing" };
    }
    if (inputs.locallyOff[product.key]) {
      return { key: product.key, enabled: false, reason: "locally-off" };
    }
    const channelCount = inputs.enabledChannelCount[product.key] ?? 0;
    if (!product.channelless && channelCount === 0) {
      return { key: product.key, enabled: false, reason: "no-channels" };
    }
    return { key: product.key, enabled: true, reason: "granted" };
  });
}
