import type { Candidate, ClassifierContext } from "./types";

export type UserLinkedContact = {
  id: string;
  email: string | null;
  name: string | null;
};

export type PriorityHierarchy = {
  id: string;
  title: string;
  /**
   * Display path for prompts. In the flat focus model there is no nesting, so
   * this is just the focus title (kept for prompt-rendering call sites that
   * still read it; no longer ltree-derived).
   */
  path: string;
  /** Same as path in the flat model — the focus title. */
  breadcrumb: string;
  description: string | null;
  /**
   * The focus's role (the grouping layer the classifier treats as the
   * "hierarchy"). Falls back to the focus itself when it has no role.
   */
  hierarchyId: string;
  hierarchyTitle: string;
};

/** Map<userContactId, Map<hierarchyId, threadCount>> */
export type AccountHierarchyAffinity = Map<string, Map<string, number>>;

export async function fetchUserLinkedContacts(
  ctx: ClassifierContext
): Promise<UserLinkedContact[]> {
  const res = await ctx.rawQuery(
    `SELECT c.id, c.email, c.name
       FROM public.user_contact uc
       JOIN public.contact c ON c.id = uc.contact_id
      WHERE uc.user_id = $1::uuid
        AND uc.linked = TRUE
        AND uc.archived_at IS NULL`,
    [ctx.userId]
  );
  return res.rows as UserLinkedContact[];
}

export async function fetchPriorityHierarchies(
  ctx: ClassifierContext
): Promise<Map<string, PriorityHierarchy>> {
  // The "hierarchy" is now the focus's role (a flat grouping layer), not the
  // depth-2 ltree ancestor. In the flat model focuses have no nesting, so the
  // display path/breadcrumb is just the focus title.
  const res = await ctx.rawQuery(
    `SELECT p.id,
            p.title,
            p.description,
            p.role_id AS hierarchy_id,
            r.name    AS hierarchy_title
       FROM public.priority p
       LEFT JOIN public.role r ON r.id = p.role_id
      WHERE p.user_id = $1::uuid
        AND p.archived_at IS NULL`,
    [ctx.userId]
  );
  const out = new Map<string, PriorityHierarchy>();
  for (const r of res.rows as {
    id: string;
    title: string;
    description: string | null;
    hierarchy_id: string | null;
    hierarchy_title: string | null;
  }[]) {
    out.set(r.id, {
      id: r.id,
      title: r.title,
      path: r.title,
      description: r.description,
      breadcrumb: r.title,
      hierarchyId: r.hierarchy_id ?? r.id,
      hierarchyTitle: r.hierarchy_title ?? r.title,
    });
  }
  return out;
}

/**
 * For each user-linked contact, count the user's training threads that
 * were authored by (or received as) that contact, grouped by the role of
 * where they were filed. This is the "this account historically lands in
 * this role" distribution.
 */
export async function fetchAccountHierarchyAffinity(
  ctx: ClassifierContext,
  linkedContactIds: string[]
): Promise<AccountHierarchyAffinity> {
  if (linkedContactIds.length === 0) return new Map();
  // Count training threads per (user-linked contact, role) where the
  // contact is EITHER the author (user-composed threads) OR appears in
  // thread.contacts (received threads — Plot's connectors put the
  // receiving user-linked contact into thread.contacts).
  const res = await ctx.rawQuery(
    `SELECT linked.cid          AS user_contact_id,
            p.role_id           AS hierarchy_id,
            COUNT(DISTINCT t.id)::int AS n
       FROM public.thread_priority tp
       JOIN public.thread t   ON t.id = tp.thread_id
       JOIN public.priority p ON p.id = tp.priority_id
       CROSS JOIN UNNEST($2::uuid[]) AS linked(cid)
      WHERE tp.user_id = $1::uuid
        AND tp.user_moved = TRUE
        AND t.archived_at IS NULL
        AND p.role_id IS NOT NULL
        AND (linked.cid = t.created_by OR linked.cid = ANY(t.contacts))
      GROUP BY linked.cid, p.role_id`,
    [ctx.userId, linkedContactIds]
  );
  const m: AccountHierarchyAffinity = new Map();
  for (const r of res.rows as {
    user_contact_id: string;
    hierarchy_id: string;
    n: number;
  }[]) {
    let inner = m.get(r.user_contact_id);
    if (!inner) {
      inner = new Map();
      m.set(r.user_contact_id, inner);
    }
    inner.set(r.hierarchy_id, r.n);
  }
  return m;
}

/**
 * Returns the user-linked contacts associated with this candidate. Today
 * we look at candidate.author (the thread author) and candidate.contacts
 * — either can reveal which account the thread came in on.
 */
export function detectCandidateAccounts(
  candidate: Candidate,
  linkedContactIds: Set<string>
): string[] {
  const out = new Set<string>();
  if (candidate.author && linkedContactIds.has(candidate.author)) {
    out.add(candidate.author);
  }
  for (const c of candidate.contacts) {
    if (linkedContactIds.has(c)) out.add(c);
  }
  return [...out];
}

/**
 * P(hierarchy | account), max-pooled across the candidate's accounts.
 * Returns 0 when we have no signal for any of the candidate's accounts.
 */
export function hierarchyAffinityScore(
  hierarchyId: string,
  candidateAccounts: string[],
  affinity: AccountHierarchyAffinity
): number {
  let best = 0;
  for (const a of candidateAccounts) {
    const dist = affinity.get(a);
    if (!dist) continue;
    const total = [...dist.values()].reduce((s, v) => s + v, 0);
    if (total === 0) continue;
    const count = dist.get(hierarchyId) ?? 0;
    const p = count / total;
    if (p > best) best = p;
  }
  return best;
}

export function labelAccount(c: UserLinkedContact): string {
  return c.email ?? c.name ?? c.id.slice(0, 8);
}

/**
 * Render a "User accounts → hierarchy filing history" block for LLM
 * prompts. Returns the empty string when there's no signal to show.
 */
export function renderAccountAffinityBlock(
  linkedContacts: UserLinkedContact[],
  affinity: AccountHierarchyAffinity,
  hierarchies: Map<string, PriorityHierarchy>
): string {
  if (linkedContacts.length === 0) return "";
  const lines: string[] = [];
  for (const a of linkedContacts) {
    const dist = affinity.get(a.id);
    if (!dist || dist.size === 0) continue;
    const total = [...dist.values()].reduce((s, v) => s + v, 0);
    const parts: string[] = [];
    for (const [hid, n] of [...dist.entries()].sort((x, y) => y[1] - x[1])) {
      const hierarchy = hierarchies.get(hid);
      const title = hierarchy?.hierarchyTitle ?? hid.slice(0, 8);
      parts.push(`${title} (${n}/${total})`);
    }
    lines.push(`  - ${labelAccount(a)}: ${parts.join(", ")}`);
  }
  if (lines.length === 0) return "";
  return "User accounts → hierarchy filing history:\n" + lines.join("\n");
}
