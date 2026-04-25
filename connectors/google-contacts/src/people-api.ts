/**
 * Reusable Google People API helpers shared by Google connectors.
 *
 * Lets any Google connector (Gmail, Calendar, Chat, Drive…) enrich contacts
 * with names and avatar URLs from the user's saved contacts and "other
 * contacts" (people they've corresponded with via Gmail) without requiring
 * the separate Google Contacts connector to be installed.
 *
 * The scopes in {@link GOOGLE_PEOPLE_SCOPES} must be granted; without them
 * `lookupGooglePeople`/`enrichContactsFromGoogle` are no-ops.
 */
import type { NewContact } from "@plotday/twister";
import type {
  NewActor,
  NewLinkWithNotes,
} from "@plotday/twister/plot";

const PEOPLE_BASE = "https://people.googleapis.com/v1";

const SCOPE_CONTACTS_RO =
  "https://www.googleapis.com/auth/contacts.readonly";
const SCOPE_OTHER_RO =
  "https://www.googleapis.com/auth/contacts.other.readonly";

/** Scopes the People API helpers depend on. Merge into your connector's
 * `scopes` (via `Integrations.MergeScopes`) to enable enrichment. */
export const GOOGLE_PEOPLE_SCOPES = [
  SCOPE_CONTACTS_RO,
  SCOPE_OTHER_RO,
];

export type GoogleContact = {
  names?: Array<{ displayName?: string }>;
  emailAddresses?: Array<{ value?: string }>;
  photos?: Array<{
    url?: string;
    default?: boolean;
    metadata?: { primary?: boolean };
  }>;
};

type ListResponse = {
  connections?: GoogleContact[];
  nextPageToken?: string;
  nextSyncToken?: string;
};

type ListOtherResponse = {
  otherContacts?: GoogleContact[];
  nextPageToken?: string;
  nextSyncToken?: string;
};

type SearchResponse = {
  results?: Array<{ person?: GoogleContact }>;
};

/** Minimal People API client. Throws on unexpected errors; returns null for
 * benign "stale sync token / gone" responses so callers can retry without
 * the token. */
export class GoogleApi {
  constructor(public accessToken: string) {}

  public async call(
    method: string,
    url: string,
    params?: Record<string, unknown>,
    body?: Record<string, unknown>,
  ): Promise<unknown> {
    const query = params
      ? `?${new URLSearchParams(
          Object.fromEntries(
            Object.entries(params).map(([k, v]) => [k, String(v)]),
          ),
        )}`
      : "";
    const headers: Record<string, string> = {
      Authorization: `Bearer ${this.accessToken}`,
      Accept: "application/json",
      ...(body ? { "Content-Type": "application/json" } : {}),
    };
    const response = await fetch(url + query, {
      method,
      headers,
      ...(body ? { body: JSON.stringify(body) } : {}),
    });
    switch (response.status) {
      case 400: {
        const responseBody = await response.json();
        if (
          (responseBody as { status?: string }).status === "FAILED_PRECONDITION"
        ) {
          return null;
        }
        throw new Error("Invalid request", { cause: responseBody });
      }
      case 401:
        throw new Error("Authentication failed - token may be expired");
      case 410:
        return null;
      case 200:
        return await response.json();
      default:
        throw new Error(await response.text());
    }
  }
}

/** Pull `{ name, avatar }` off a Person resource. Skips Google's generic
 * default avatar (gray silhouette) — those `default: true` entries should
 * never overwrite anything useful. */
export function parseContact(contact: GoogleContact): {
  name?: string;
  avatar?: string;
} {
  const name = contact.names?.[0]?.displayName;
  const avatar = contact.photos?.find(
    (p) => !p.default && p.metadata?.primary,
  )?.url;
  return {
    ...(name ? { name } : {}),
    ...(avatar ? { avatar } : {}),
  };
}

export type ContactSyncState = {
  more?: boolean;
  state?: string;
};

type ContactTokens = {
  connections?: { nextPageToken?: string; nextSyncToken?: string };
  other?: { nextPageToken?: string; nextSyncToken?: string };
};

/**
 * Bulk-fetches the user's Google Contacts. Used by the Google Contacts
 * connector for full sync. Other connectors should typically use
 * {@link enrichContactsFromGoogle} for targeted enrichment instead.
 */
export async function getGoogleContacts(
  api: GoogleApi,
  scopes: string[],
  state: ContactSyncState,
): Promise<{
  contacts: NewContact[];
  state: ContactSyncState;
}> {
  let tokens = JSON.parse(state.state ?? "{}") as ContactTokens;
  const contacts: Record<string, NewContact> = {};
  let more = false;

  if (!state.more || tokens.connections?.nextPageToken) {
    if (scopes?.some?.((scope) => scope === SCOPE_CONTACTS_RO)) {
      let response: ListResponse | undefined;
      while (true) {
        response = (await api.call(
          "GET",
          `${PEOPLE_BASE}/people/me/connections`,
          {
            requestSyncToken: true,
            ...(tokens.connections?.nextPageToken
              ? { pageToken: tokens.connections.nextPageToken }
              : tokens.connections?.nextSyncToken
              ? { syncToken: tokens.connections.nextSyncToken }
              : {}),
            personFields: "names,emailAddresses,photos",
          },
        )) as ListResponse;
        if (response !== null) break;
        if (!tokens.connections) break;
        tokens.connections = undefined;
        continue;
      }
      if (response) {
        for (const c of response.connections ?? []) {
          for (const e of c.emailAddresses ?? []) {
            if (!e.value) continue;
            const { name, avatar } = parseContact(c);
            contacts[e.value] = {
              ...contacts[e.value],
              email: e.value,
              ...(name ? { name } : {}),
              ...(avatar ? { avatar } : {}),
            };
          }
        }
        more = true;
        tokens = {
          ...tokens,
          connections: {
            nextPageToken: response.nextPageToken ?? undefined,
            nextSyncToken: response.nextSyncToken ?? undefined,
          },
        };
      }
    } else {
      more = true;
      tokens = { ...tokens, connections: {} };
    }
  } else {
    if (scopes?.some?.((scope) => scope === SCOPE_OTHER_RO)) {
      let response: ListOtherResponse | undefined;
      while (true) {
        response = (await api.call(
          "GET",
          `${PEOPLE_BASE}/otherContacts`,
          {
            requestSyncToken: true,
            ...(tokens.other?.nextPageToken
              ? { pageToken: tokens.other.nextPageToken }
              : tokens.other?.nextSyncToken
              ? { syncToken: tokens.other.nextSyncToken }
              : {}),
            readMask: "names,emailAddresses,photos",
          },
        )) as ListOtherResponse;
        if (response !== null) break;
        if (!tokens.other) break;
        tokens.other = undefined;
        continue;
      }
      if (response) {
        for (const c of response.otherContacts ?? []) {
          for (const e of c.emailAddresses ?? []) {
            if (!e.value) continue;
            const { name, avatar } = parseContact(c);
            contacts[e.value] = {
              ...contacts[e.value],
              email: e.value,
              ...(name ? { name } : {}),
              ...(avatar ? { avatar } : {}),
            };
          }
        }
        more = !!response.nextPageToken;
        tokens = {
          ...tokens,
          other: {
            nextPageToken: response.nextPageToken ?? undefined,
            nextSyncToken: response.nextSyncToken ?? undefined,
          },
        };
      }
    } else {
      more = false;
      tokens = { ...tokens, other: {} };
    }
  }

  return {
    contacts: Object.values(contacts),
    state: { more, state: JSON.stringify(tokens) },
  };
}

async function searchByEmail(
  api: GoogleApi,
  endpoint: string,
  email: string,
): Promise<GoogleContact[]> {
  try {
    const data = (await api.call("GET", `${PEOPLE_BASE}/${endpoint}`, {
      query: email,
      readMask: "names,emailAddresses,photos",
      pageSize: 5,
    })) as SearchResponse | null;
    if (!data) return [];
    return (data.results ?? [])
      .map((r) => r.person)
      .filter((p): p is GoogleContact => !!p);
  } catch {
    // Search APIs occasionally return transient errors or 404 on cold cache;
    // partial enrichment is fine — just skip this email.
    return [];
  }
}

/**
 * Look up Google's People API for each email and return a name/avatar
 * enrichment map keyed by lowercased email.
 *
 * Tries `otherContacts:search` first (people the user has corresponded
 * with — best fit for Gmail) and falls back to `people:searchContacts`
 * (the user's saved contacts) for emails that don't match. Whichever
 * scopes are granted are used; missing scopes are silently skipped.
 */
export async function lookupGooglePeople(
  token: string,
  scopes: string[],
  emails: string[],
): Promise<Record<string, { name?: string; avatar?: string }>> {
  const result: Record<string, { name?: string; avatar?: string }> = {};
  const unique = Array.from(
    new Set(emails.map((e) => e.toLowerCase().trim()).filter(Boolean)),
  );
  if (unique.length === 0) return result;

  const hasContacts = scopes.includes(SCOPE_CONTACTS_RO);
  const hasOther = scopes.includes(SCOPE_OTHER_RO);
  if (!hasContacts && !hasOther) return result;

  const api = new GoogleApi(token);

  await Promise.all(
    unique.map(async (email) => {
      const candidates: GoogleContact[] = [];
      if (hasOther) {
        candidates.push(
          ...(await searchByEmail(api, "otherContacts:search", email)),
        );
      }
      if (candidates.length === 0 && hasContacts) {
        candidates.push(
          ...(await searchByEmail(api, "people:searchContacts", email)),
        );
      }
      const match = candidates.find((p) =>
        p.emailAddresses?.some(
          (e) => e.value?.toLowerCase().trim() === email,
        ),
      );
      if (!match) return;
      const parsed = parseContact(match);
      if (parsed.name || parsed.avatar) result[email] = parsed;
    }),
  );

  return result;
}

/**
 * Walk every contact slot inside a batch of `NewLinkWithNotes` (thread-level
 * `accessContacts` plus per-note `author` and `accessContacts`), and fill
 * in missing `name`/`avatar` from Google's People API. Mutates the links
 * in place. Existing non-null fields are preserved.
 *
 * Designed to be called once per batch so a connector makes a single People
 * API pass for all unique emails in the batch, instead of one pass per
 * thread/event. Skips `ActorId` strings (already-resolved contacts) and
 * entries without an email (the People API can only look up by email).
 */
export async function enrichLinkContactsFromGoogle(
  links: NewLinkWithNotes[],
  token: string,
  scopes: string[],
): Promise<void> {
  type Holder = { email: string; name?: string; avatar?: string };
  const holders: Holder[] = [];

  const visit = (c: unknown) => {
    if (!c || typeof c !== "object") return;
    const cc = c as { email?: string; name?: string; avatar?: string };
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

  if (holders.length === 0) return;

  // enrichContactsFromGoogle preserves order, so we can apply results back
  // onto the original references in lockstep.
  const enriched = await enrichContactsFromGoogle(
    token,
    scopes,
    holders as NewContact[],
  );
  for (let i = 0; i < holders.length; i++) {
    const updated = enriched[i] as { name?: string; avatar?: string };
    const holder = holders[i];
    if (!holder.name && updated.name) holder.name = updated.name;
    if (!holder.avatar && updated.avatar) holder.avatar = updated.avatar;
  }
}

/**
 * Fill in missing `name`/`avatar` on contacts from Google's People API.
 * Existing non-null fields are preserved. Connectors call this before
 * `saveLink` / `saveContacts` to enrich contacts they only see by email
 * (Gmail headers, Calendar attendees, …) without requiring users to
 * install the separate Google Contacts connector.
 *
 * No-op when none of {@link GOOGLE_PEOPLE_SCOPES} is granted, when no
 * contacts need enrichment, or when the API returns nothing useful — so
 * it's safe to call unconditionally.
 */
export async function enrichContactsFromGoogle(
  token: string,
  scopes: string[],
  contacts: NewContact[],
): Promise<NewContact[]> {
  const emailsToLookup = contacts
    .filter((c): c is NewContact & { email: string } =>
      !!c.email && (!c.name || !c.avatar),
    )
    .map((c) => c.email);
  if (emailsToLookup.length === 0) return contacts;
  const map = await lookupGooglePeople(token, scopes, emailsToLookup);
  if (Object.keys(map).length === 0) return contacts;
  return contacts.map((c) => {
    if (!c.email) return c;
    const enrich = map[c.email.toLowerCase().trim()];
    if (!enrich) return c;
    return {
      ...c,
      ...(!c.name && enrich.name ? { name: enrich.name } : {}),
      ...(!c.avatar && enrich.avatar ? { avatar: enrich.avatar } : {}),
    };
  });
}
