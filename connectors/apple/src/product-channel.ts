/**
 * Product-channel id namespacing helpers.
 *
 * Convention: namespaced id = "<product>:<rawId>", split on the FIRST ':'.
 * Products: "calendar", "mail". Mirrors google's product-channel.ts and the
 * Flutter-side convention in apps/plot/lib/util/product_channel.dart.
 */

/** Returns a namespaced channel id: "<product>:<rawId>". */
export function namespace(product: string, rawId: string): string {
  return `${product}:${rawId}`;
}

/** Splits a namespaced id on the first ':'. If no ':' exists, product is "". */
export function parse(nsId: string): { product: string; rawId: string } {
  const idx = nsId.indexOf(":");
  if (idx === -1) return { product: "", rawId: nsId };
  return { product: nsId.slice(0, idx), rawId: nsId.slice(idx + 1) };
}

/** Returns the product key (before the first ':'), or null if unprefixed. */
export function productKeyOf(nsId: string): string | null {
  const idx = nsId.indexOf(":");
  if (idx === -1) return null;
  return nsId.slice(0, idx);
}
