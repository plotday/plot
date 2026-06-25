/**
 * Product-channel id namespacing helpers.
 *
 * These are the ONLY place channel ids are namespaced/parsed in this package.
 * Mirrors the Dart-side convention in apps/plot/lib/util/product_channel.dart.
 *
 * Convention: namespaced id = "<product>:<rawId>"
 *   - product is one of: mail, calendar, contacts
 *   - rawId may itself contain ':' — we split on the FIRST ':' only
 */

/** Returns a namespaced channel id: "<product>:<rawId>". */
export function namespace(product: string, rawId: string): string {
  return `${product}:${rawId}`;
}

/** Splits a namespaced id on the first ':'. If no ':' exists, product is "". */
export function parse(nsId: string): { product: string; rawId: string } {
  const idx = nsId.indexOf(":");
  if (idx === -1) {
    return { product: "", rawId: nsId };
  }
  return { product: nsId.slice(0, idx), rawId: nsId.slice(idx + 1) };
}

/**
 * Returns the product key (substring before the first ':'), or null if
 * the id has no prefix.
 *
 * Mirrors Dart's `productKeyOf` in apps/plot/lib/util/product_channel.dart.
 */
export function productKeyOf(nsId: string): string | null {
  const idx = nsId.indexOf(":");
  if (idx === -1) return null;
  return nsId.slice(0, idx);
}
