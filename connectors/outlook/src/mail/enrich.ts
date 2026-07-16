/**
 * Contact enrichment from Microsoft Graph People + Contacts APIs.
 *
 * Names only: Graph photos ( /me/contacts/{id}/photo/$value ) are auth-gated
 * binary with no public URL, so they can't populate `contact.avatar` (a URL
 * field). Client-side Gravatar remains the avatar fallback.
 *
 * Scope behavior: each lookup path is attempted only when its scope was
 * granted; 403s (work-tenant admin-consent denials, consumer People API
 * limitations) are swallowed per-email — enrichment is always best-effort.
 */
import type {
  NewActor,
  NewContact,
  NewLinkWithNotes,
} from "@plotday/twister/plot";

const GRAPH = "https://graph.microsoft.com/v1.0";
const SCOPE_PEOPLE = "https://graph.microsoft.com/people.read";
const SCOPE_CONTACTS = "https://graph.microsoft.com/contacts.read";

/** Scopes the enrichment helpers depend on. Merge into the connector's
 * `scopes` (via `Integrations.MergeScopes`) to enable enrichment. */
export const OUTLOOK_PEOPLE_SCOPES = [SCOPE_PEOPLE, SCOPE_CONTACTS];

type GraphPerson = {
  displayName?: string;
  scoredEmailAddresses?: Array<{ address?: string }>;
  emailAddresses?: Array<{ address?: string }>;
};

async function graphGet(
  token: string,
  url: string,
  params: Record<string, string>
): Promise<any | null> {
  try {
    const response = await fetch(`${url}?${new URLSearchParams(params)}`, {
      headers: { Authorization: `Bearer ${token}`, Accept: "application/json" },
    });
    if (!response.ok) return null; // 403/404/429 — per-email best effort
    return await response.json();
  } catch {
    return null;
  }
}

function personMatches(p: GraphPerson, email: string): boolean {
  const all = [
    ...(p.scoredEmailAddresses ?? []).map((e) => e.address),
    ...(p.emailAddresses ?? []).map((e) => e.address),
  ];
  return all.some((a) => a?.toLowerCase().trim() === email);
}

/** Per-email name lookup: /me/people $search first, /me/contacts $filter fallback. */
export async function lookupOutlookPeople(
  token: string,
  scopes: string[],
  emails: string[]
): Promise<Record<string, { name?: string }>> {
  const result: Record<string, { name?: string }> = {};
  const unique = Array.from(
    new Set(emails.map((e) => e.toLowerCase().trim()).filter(Boolean))
  );
  const hasPeople = scopes.includes(SCOPE_PEOPLE);
  const hasContacts = scopes.includes(SCOPE_CONTACTS);
  if (unique.length === 0 || (!hasPeople && !hasContacts)) return result;

  await Promise.all(
    unique.map(async (email) => {
      let name: string | undefined;
      if (hasPeople) {
        const data = await graphGet(token, `${GRAPH}/me/people`, {
          $search: `"${email}"`,
          $select: "displayName,scoredEmailAddresses",
          $top: "5",
        });
        const match = (data?.value as GraphPerson[] | undefined)?.find((p) =>
          personMatches(p, email)
        );
        if (match?.displayName) name = match.displayName;
      }
      if (!name && hasContacts) {
        const data = await graphGet(token, `${GRAPH}/me/contacts`, {
          $filter: `emailAddresses/any(a:a/address eq '${email.replace(/'/g, "''")}')`,
          $select: "displayName,emailAddresses",
          $top: "5",
        });
        const match = (data?.value as GraphPerson[] | undefined)?.find((p) =>
          personMatches(p, email)
        );
        if (match?.displayName) name = match.displayName;
      }
      if (name) result[email] = { name };
    })
  );
  return result;
}

/**
 * Fill missing contact names across a batch of links (thread accessContacts +
 * note authors + note accessContacts). Mutates in place; existing names win.
 * Designed to be called once per sync batch so a single People/Contacts pass
 * covers every unique email in the batch.
 */
export async function enrichLinkContactsFromOutlook(
  links: NewLinkWithNotes[],
  token: string,
  scopes: string[]
): Promise<void> {
  type Holder = { email: string; name?: string };
  const holders: Holder[] = [];
  const visit = (c: unknown) => {
    if (!c || typeof c !== "object") return;
    const cc = c as { email?: string };
    if (typeof cc.email !== "string" || cc.email.length === 0) return;
    holders.push(cc as Holder);
  };
  for (const link of links) {
    visit((link as { author?: NewActor }).author);
    for (const c of link.accessContacts ?? []) visit(c);
    for (const note of link.notes ?? []) {
      const n = note as {
        author?: NewActor;
        accessContacts?: Array<NewContact | string>;
      };
      visit(n.author);
      for (const c of n.accessContacts ?? []) visit(c);
    }
  }
  const needing = holders.filter((h) => !h.name).map((h) => h.email);
  if (needing.length === 0) return;
  const map = await lookupOutlookPeople(token, scopes, needing);
  if (Object.keys(map).length === 0) return;
  for (const holder of holders) {
    const found = map[holder.email.toLowerCase().trim()];
    if (!holder.name && found?.name) holder.name = found.name;
  }
}
