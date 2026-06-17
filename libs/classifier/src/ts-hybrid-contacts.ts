import type { ClassifierContext } from "./types";

/**
 * Maps each input contact id to the linked-alias contact ids of every user
 * that owns it. Built once per classify job and reused to expand many threads'
 * contact arrays in JS — see {@link buildAliasMap} / {@link expandWithAliasMap}.
 */
export type AliasMap = Map<string, string[]>;

/**
 * Batched, JS-side equivalent of `public.expand_contacts`.
 *
 * The scoring stage compares contact overlap between a candidate and every
 * training thread, with both sides expanded to include linked aliases (so the
 * same human reached via work + personal email counts as overlapping). The SQL
 * function `public.expand_contacts(contacts)` does this per array, but it is a
 * STABLE function with a UNION (so Postgres cannot inline it). Calling it once
 * per training row meant 1500+ separate executor invocations per classify job —
 * ~11s on a moderate training set, crossing the worker's 30s statement_timeout
 * and stranding the user's threads unclassified.
 *
 * Instead we fetch the alias edges for the WHOLE distinct contact set in one
 * query and expand each thread's contacts in JS. The result is identical to
 * `expand_contacts` (verified row-for-row against production): the raw contacts
 * unioned with every linked alias of any user that owns one of them, deduped.
 */
export async function buildAliasMap(
  ctx: ClassifierContext,
  contacts: Iterable<string>
): Promise<AliasMap> {
  const distinct = [...new Set(contacts)];
  const map: AliasMap = new Map();
  if (distinct.length === 0) return map;

  const res = await ctx.rawQuery(
    `SELECT uc1.contact_id AS input, uc2.contact_id AS alias
       FROM public.user_contact uc1
       JOIN public.user_contact uc2
         ON uc2.user_id = uc1.user_id
        AND uc2.linked = TRUE
        AND uc2.archived_at IS NULL
      WHERE uc1.contact_id = ANY($1::uuid[])
        AND uc1.linked = TRUE
        AND uc1.archived_at IS NULL`,
    [distinct]
  );

  for (const r of res.rows as Array<{ input: string; alias: string }>) {
    const arr = map.get(r.input);
    if (arr) arr.push(r.alias);
    else map.set(r.input, [r.alias]);
  }
  return map;
}

/**
 * Expand one thread's contact array using a prebuilt {@link AliasMap}. The
 * input contacts are always retained (even when unlinked / absent from the
 * map); each contact additionally contributes its owners' linked aliases.
 * Deduplicated. Equivalent to `public.expand_contacts(contacts)`.
 */
export function expandWithAliasMap(
  contacts: string[],
  aliases: AliasMap
): string[] {
  if (contacts.length === 0) return [];
  const out = new Set<string>(contacts);
  for (const c of contacts) {
    const extra = aliases.get(c);
    if (extra) for (const a of extra) out.add(a);
  }
  return [...out];
}
