import type { AuthToken, Channel } from "@plotday/twister/tools/integrations";
import type { Product } from "./products/product";
import { namespace, productKeyOf } from "./product-channel";

/**
 * Prefixes a channel's id (and recursively its children's ids) with the
 * product key, and attaches the product's linkTypes to each channel.
 * Title remains un-prefixed.
 */
function prefixChannel(productKey: string, channel: Channel, linkTypes: Product["linkTypes"]): Channel {
  return {
    ...channel,
    id: namespace(productKey, channel.id),
    linkTypes,
    ...(channel.children
      ? {
          children: channel.children.map((child) =>
            prefixChannel(productKey, child, linkTypes)
          ),
        }
      : {}),
  };
}

/**
 * Composes channels from all products whose requiredScopes are a subset of
 * token.scopes. Each channel is namespaced and linked-typed.
 *
 * This is a pure function — injectable with fake products for testing.
 */
export async function composeChannels(
  products: Product[],
  token: AuthToken
): Promise<Channel[]> {
  const grantedScopes = new Set(token.scopes ?? []);

  // Enumerate every eligible product concurrently (each getRawChannels is an
  // independent network call to Google). Order is preserved by enumerating
  // results in `eligible` order, which is products' declaration order.
  const eligible = products.filter((product) =>
    product.requiredScopes.every((s) => grantedScopes.has(s))
  );
  const perProduct = await Promise.all(
    eligible.map((product) => product.getRawChannels(token))
  );

  const result: Channel[] = [];
  eligible.forEach((product, i) => {
    for (const raw of perProduct[i]) {
      result.push(prefixChannel(product.key, raw, product.linkTypes));
    }
  });
  return result;
}

/**
 * Resolves the owning product for a namespaced channel id.
 * Returns null if the id has no prefix or the prefix doesn't match any product.
 *
 * This is a pure function — injectable with fake products for testing.
 */
export function resolveProductForChannelId(
  products: Product[],
  nsId: string
): Product | null {
  const key = productKeyOf(nsId);
  if (!key) return null;
  return products.find((p) => p.key === key) ?? null;
}

/**
 * Resolves the owning product for a link type string.
 * Link types are disjoint per product (each type belongs to exactly one product).
 * Returns null if no product declares this link type.
 *
 * This is a pure function — injectable with fake products for testing.
 */
export function resolveProductForLinkType(
  products: Product[],
  linkType: string
): Product | null {
  return (
    products.find((p) => p.linkTypes.some((lt) => lt.type === linkType)) ?? null
  );
}
