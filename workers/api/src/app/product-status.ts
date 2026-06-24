/**
 * Per-product enablement computation for combined (multi-product) connectors
 * (e.g. the combined Google connector: Mail, Calendar, Tasks, Contacts).
 *
 * Pure functions — no DB, no Durable Objects — so they can be unit-tested in
 * isolation. The integrations endpoint feeds them the declared products, the
 * provider's optional scope groups, the connection's granted scopes, and the
 * enabled channels.
 *
 * Frozen contract (spec §4.2): each product maps to one optional scope group
 * via `scopeGroupId === OptionalScopeGroup.id`. The product's required scopes
 * are that group's `scopes`. A channel belongs to a product when its
 * namespaced id prefix (substring before the first ":") equals the product key.
 */

/** Product metadata declared by a combined connector. */
export type ProductInfo = {
  key: string;
  label: string;
  description: string;
  icon: string;
  scopeGroupId: string;
};

/** An optional scope group declared in the provider's ScopeConfig. */
export type OptionalScopeGroup = {
  id: string;
  scopes: string[];
};

/** Per-product enablement, mirrored into the integrations response. */
export type ProductStatus = {
  key: string;
  enabled: boolean;
  reason: "granted" | "scope-missing" | "locally-off" | "no-channels";
};

/**
 * Returns the product key for a namespaced channel id — the substring before
 * the first ":" (e.g. "calendar:primary" → "calendar"). Null when unprefixed.
 *
 * Mirrors the connector's `productKeyOf` and the Dart-side convention.
 */
export function productKeyOf(channelId: string): string | null {
  const idx = channelId.indexOf(":");
  if (idx === -1) return null;
  return channelId.slice(0, idx);
}

/**
 * Computes per-product enablement for a combined connector.
 *
 * Rules (per product, in order):
 *  - required scopes ⊄ granted   → `{ enabled: false, reason: "scope-missing" }`
 *  - else enabledChannelCount===0 → `{ enabled: false, reason: "no-channels" }`
 *  - else                         → `{ enabled: true,  reason: "granted" }`
 *
 * `"locally-off"` is not produced here — there is no explicit server-side
 * local-off flag yet; turning a product off disables its channels, which
 * surfaces as `"no-channels"`. (Spec §2.4 / §4.4.)
 *
 * Required scopes for a product come from the optional scope group whose `id`
 * equals the product's `scopeGroupId`. If no matching group is found, the
 * product is treated as having no required scopes (so it can never be
 * `scope-missing`).
 *
 * @param products            Declared products (from connector metadata).
 * @param optionalScopeGroups The provider's optional scope groups.
 * @param grantedScopes       Scopes actually granted on the connection.
 * @param enabledChannelIds   Namespaced ids of channels currently enabled.
 */
export function computeProductStatus(
  products: ProductInfo[],
  optionalScopeGroups: OptionalScopeGroup[],
  grantedScopes: string[],
  enabledChannelIds: string[],
): ProductStatus[] {
  const granted = new Set(grantedScopes);
  const groupById = new Map(optionalScopeGroups.map((g) => [g.id, g]));

  // Count enabled channels per product key (prefix before first ":").
  const enabledCountByKey = new Map<string, number>();
  for (const id of enabledChannelIds) {
    const key = productKeyOf(id);
    if (key == null) continue;
    enabledCountByKey.set(key, (enabledCountByKey.get(key) ?? 0) + 1);
  }

  return products.map((product) => {
    const requiredScopes = groupById.get(product.scopeGroupId)?.scopes ?? [];
    const hasAllScopes = requiredScopes.every((s) => granted.has(s));
    if (!hasAllScopes) {
      return { key: product.key, enabled: false, reason: "scope-missing" };
    }
    const enabledChannelCount = enabledCountByKey.get(product.key) ?? 0;
    if (enabledChannelCount === 0) {
      return { key: product.key, enabled: false, reason: "no-channels" };
    }
    return { key: product.key, enabled: true, reason: "granted" };
  });
}
