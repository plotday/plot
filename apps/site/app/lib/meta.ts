import type { MetaDescriptor } from "react-router";

/** Default meta tags inherited by all routes via mergeMeta. */
export const DEFAULT_META: MetaDescriptor[] = [
  { property: "og:image", content: "https://plot.day/assets/og-image.png" },
  { name: "twitter:image", content: "https://plot.day/assets/og-image.png" },
];

/**
 * Returns a meta key for deduplication.
 * Handles title, name-based, property-based (og:*, twitter:*), and tagName entries.
 */
function metaKey(entry: MetaDescriptor): string | null {
  if ("title" in entry) return "title";
  if ("name" in entry) return `name:${(entry as any).name}`;
  if ("property" in entry) return (entry as any).property;
  if ("tagName" in entry) return null; // no dedup for raw tags

  // Shorthand property-based entries like { "og:image": "..." }
  for (const key of Object.keys(entry)) {
    if (key.startsWith("og:") || key.startsWith("twitter:")) return key;
  }
  return null;
}

/**
 * Merges DEFAULT_META with route-specific meta.
 * Route entries override defaults with the same key.
 */
export function mergeMeta(routeMeta: MetaDescriptor[]): MetaDescriptor[] {
  const routeKeys = new Set(routeMeta.map(metaKey).filter(Boolean));
  const defaults = DEFAULT_META.filter((d) => {
    const key = metaKey(d);
    return key && !routeKeys.has(key);
  });
  return [...defaults, ...routeMeta];
}
