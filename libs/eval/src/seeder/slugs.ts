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
 * Derives a contact slug from an ANONYMIZED email's local part. Works for
 * both the v2 anonymizer's realistic shapes (`jordan.mercer@lumenforge.com`
 * -> `jordan-mercer`, `c-1a2b3c4d5e6f@gmail.com` -> `c-1a2b3c4d5e6f`) and the
 * legacy v1 shape (`c-XXXX@example.test`). Falls back to a generic
 * short-hash slug derived from the id when the email is missing or yields
 * nothing slug-shaped.
 *
 * Only ever call this with an anonymized email — a raw email's local part
 * would leak straight into the slug.
 */
export function contactSlugFromEmail(email: string | null, id: string): string {
  if (email) {
    const at = email.lastIndexOf("@");
    const local = at > 0 ? email.slice(0, at) : email;
    const slug = local
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "");
    if (slug) return slug;
  }
  // Last resort: derive from id.
  return `c-${id.replace(/-/g, "").slice(0, 8)}`;
}
