/**
 * Slug generation. Produces stable, kebab-case identifiers from human text.
 * The seeder uses these so the corpus YAMLs read naturally for manual review
 * (priorities like `engineering` instead of UUIDs).
 */

function slugify(input: string): string {
  return input
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[^\w\s-]/g, "")
    .trim()
    .replace(/[\s_]+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-+|-+$/g, "");
}

export function uniqueSlugifier(
  preseed?: Iterable<string>
): (input: string, fallback?: string) => string {
  const used = new Set<string>(preseed);
  return (input, fallback) => {
    let base = slugify(input);
    if (!base && fallback) base = slugify(fallback);
    if (!base) base = "item";
    let candidate = base;
    let i = 2;
    while (used.has(candidate)) {
      candidate = `${base}-${i++}`;
    }
    used.add(candidate);
    return candidate;
  };
}

/**
 * For contacts whose email matches the anonymized pattern
 * `c-XXXXXXXX@example.test`, return the local-part as the slug. Falls back
 * to a generic short-hash slug derived from the id.
 */
export function contactSlugFromEmail(email: string | null, id: string): string {
  if (email) {
    const m = email.match(/^([a-z0-9-]+)@example\.test$/);
    if (m) return m[1]!;
  }
  // Last resort: derive from id.
  return `c-${id.replace(/-/g, "").slice(0, 8)}`;
}
