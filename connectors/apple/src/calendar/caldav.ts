declare const Buffer: {
  from(
    data: string | ArrayBuffer | Uint8Array,
    encoding?: string
  ): Uint8Array & { toString(encoding?: string): string };
};

export type CalDAVCredentials = {
  appleId: string;
  appPassword: string;
};

export type CalDAVCalendar = {
  href: string;
  displayName: string;
  ctag: string | null;
};

export type CalDAVEvent = {
  href: string;
  etag: string;
  icsData: string;
};

/** A single added/modified item reported by a `sync-collection` REPORT. */
export type CalDAVCollectionChange = {
  href: string;
  etag: string;
};

/**
 * Result of an RFC 6578 WebDAV-Sync `sync-collection` REPORT: the new sync
 * token to persist for the next incremental poll, plus the hrefs that
 * changed (added or modified) and the hrefs that were deleted since the
 * token passed in.
 */
export type CalDAVCollectionChanges = {
  token: string;
  changed: CalDAVCollectionChange[];
  deletedHrefs: string[];
};

/**
 * Thrown when a `sync-collection` REPORT is rejected because the sync token
 * is invalid or expired — RFC 6578 §3.7's `DAV:valid-sync-token`
 * precondition, which iCloud surfaces as an HTTP `403` whose body is
 * `<error><valid-sync-token/></error>`, not a generic access-denied 403.
 * Callers should discard the stored token and retry with `syncToken: null`
 * for a full resync, rather than treating this like any other failure.
 */
export class InvalidSyncTokenError extends Error {
  constructor(message = "CalDAV sync token is invalid or expired") {
    super(message);
    this.name = "InvalidSyncTokenError";
  }
}

/**
 * Thrown when a PUT to `updateEventICS` is rejected with `412 Precondition
 * Failed` — the `If-Match` etag no longer matches the event's current
 * version because it was modified concurrently between the caller's GET and
 * PUT (another client's edit, another RSVP write, or a sync pass landing in
 * between). Distinguishable from a generic write failure (which still
 * resolves `updateEventICS` to `false`, unchanged) so callers can react —
 * re-read the fresh event, re-apply their patch, and retry — rather than
 * treating it like any other error. Mirrors `InvalidSyncTokenError` above.
 */
export class PreconditionFailedError extends Error {
  constructor(
    message = "CalDAV event was modified concurrently (412 Precondition Failed)"
  ) {
    super(message);
    this.name = "PreconditionFailedError";
  }
}

type MultistatusEntry = {
  href: string;
  props: Record<string, string>;
  status?: string;
};

/**
 * Lightweight CalDAV client for iCloud Calendar.
 * Uses fetch() API only — compatible with Cloudflare Workers.
 */
export class CalDAVClient {
  private baseUrl = "https://caldav.icloud.com";
  private authHeader: string;

  constructor(private credentials: CalDAVCredentials) {
    const encoded = Buffer.from(
      `${credentials.appleId}:${credentials.appPassword}`
    ).toString("base64");
    this.authHeader = `Basic ${encoded}`;
  }

  /**
   * Make a CalDAV request using fetch().
   */
  private async request(
    method: string,
    url: string,
    body?: string,
    depth?: number
  ): Promise<string> {
    const headers: Record<string, string> = {
      Authorization: this.authHeader,
      "Content-Type": "application/xml; charset=utf-8",
    };
    if (depth !== undefined) {
      headers["Depth"] = String(depth);
    }

    const response = await fetch(url, {
      method,
      headers,
      body,
      redirect: "follow",
    });

    if (response.status === 401) {
      throw new Error(
        "Authentication failed — check your Apple ID and app-specific password"
      );
    }
    if (response.status === 403) {
      // A 403 is normally a revoked app-specific password, but
      // sync-collection REPORTs also use 403 for the RFC 6578 §3.7
      // DAV:valid-sync-token precondition (invalid/expired token). Only the
      // body distinguishes them — read it and check for that specific
      // element before falling back to the generic access-denied error.
      const text = await response.text();
      if (isInvalidSyncTokenResponse(text)) {
        throw new InvalidSyncTokenError();
      }
      throw new Error("Access denied — app-specific password may be revoked");
    }
    if (!response.ok && response.status !== 207) {
      throw new Error(`CalDAV request failed: ${response.status} ${response.statusText}`);
    }

    return await response.text();
  }

  private resolveUrl(href: string): string {
    if (href.startsWith("http")) return href;
    return `${this.baseUrl}${href}`;
  }

  /**
   * Discover the CalDAV principal URL for the authenticated user.
   */
  async discoverPrincipal(): Promise<string> {
    const body = `<?xml version="1.0" encoding="UTF-8"?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:current-user-principal/>
  </d:prop>
</d:propfind>`;

    const xml = await this.request("PROPFIND", this.baseUrl + "/", body, 0);
    const entries = parseMultistatus(xml);

    for (const entry of entries) {
      const principal = entry.props["current-user-principal"];
      if (principal) return principal;
    }

    throw new Error("Could not discover CalDAV principal URL");
  }

  /**
   * Discover the calendar home URL from the principal.
   */
  async discoverCalendarHome(principalUrl: string): Promise<string> {
    const body = `<?xml version="1.0" encoding="UTF-8"?>
<d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:prop>
    <c:calendar-home-set/>
  </d:prop>
</d:propfind>`;

    const xml = await this.request(
      "PROPFIND",
      this.resolveUrl(principalUrl),
      body,
      0
    );
    const entries = parseMultistatus(xml);

    for (const entry of entries) {
      const home = entry.props["calendar-home-set"];
      if (home) return home;
    }

    throw new Error("Could not discover calendar home URL");
  }

  /**
   * List all calendars in the calendar home.
   */
  async listCalendars(calendarHomeUrl: string): Promise<CalDAVCalendar[]> {
    const body = `<?xml version="1.0" encoding="UTF-8"?>
<d:propfind xmlns:d="DAV:" xmlns:cs="http://calendarserver.org/ns/" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:prop>
    <d:displayname/>
    <cs:getctag/>
    <d:resourcetype/>
    <c:supported-calendar-component-set/>
  </d:prop>
</d:propfind>`;

    const xml = await this.request(
      "PROPFIND",
      this.resolveUrl(calendarHomeUrl),
      body,
      1
    );
    const entries = parseMultistatus(xml);

    const calendars: CalDAVCalendar[] = [];
    for (const entry of entries) {
      const resourceType = entry.props["resourcetype"] || "";
      // Require a real CalDAV <calendar> ELEMENT in resourcetype. A plain
      // substring test for "calendar" also matches the "calendarserver.org"
      // namespace URL that iCloud stamps on system collections (e.g. the
      // nameless `notification` collection), which would otherwise surface as
      // an "Untitled Calendar". Match the tag itself instead. This also
      // excludes the scheduling inbox/outbox and the account root, which are
      // plain collections with no <calendar>.
      if (!/<(?:[a-z0-9]+:)?calendar[\s/>]/i.test(resourceType)) continue;
      // Exclude non-event calendars: iCloud Reminders is a VTODO list, not an
      // events calendar. iCloud returns supported-calendar-component-set, so
      // require VEVENT; if a server omits the property, keep the calendar
      // (assume it holds events).
      const compSet = entry.props["supported-calendar-component-set"];
      if (compSet && !/VEVENT/i.test(compSet)) continue;

      calendars.push({
        href: entry.href,
        displayName: entry.props["displayname"] || "Untitled Calendar",
        ctag: entry.props["getctag"] || null,
      });
    }

    return calendars;
  }

  /**
   * Fetch events in a time range using a calendar-query REPORT.
   */
  async fetchEvents(
    calendarHref: string,
    timeRange: { start: string; end: string }
  ): Promise<CalDAVEvent[]> {
    const body = `<?xml version="1.0" encoding="UTF-8"?>
<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:prop>
    <d:getetag/>
    <c:calendar-data/>
  </d:prop>
  <c:filter>
    <c:comp-filter name="VCALENDAR">
      <c:comp-filter name="VEVENT">
        <c:time-range start="${timeRange.start}" end="${timeRange.end}"/>
      </c:comp-filter>
    </c:comp-filter>
  </c:filter>
</c:calendar-query>`;

    const xml = await this.request(
      "REPORT",
      this.resolveUrl(calendarHref),
      body,
      1
    );
    return parseEventResponses(xml);
  }

  /**
   * Get the current ctag for a calendar (change detection).
   */
  async getCalendarCtag(calendarHref: string): Promise<string | null> {
    const body = `<?xml version="1.0" encoding="UTF-8"?>
<d:propfind xmlns:d="DAV:" xmlns:cs="http://calendarserver.org/ns/">
  <d:prop>
    <cs:getctag/>
  </d:prop>
</d:propfind>`;

    const xml = await this.request(
      "PROPFIND",
      this.resolveUrl(calendarHref),
      body,
      0
    );
    const entries = parseMultistatus(xml);

    for (const entry of entries) {
      if (entry.props["getctag"]) return entry.props["getctag"];
    }

    return null;
  }

  /**
   * Get etags for all events in a calendar (for incremental sync).
   */
  async getEventEtags(
    calendarHref: string
  ): Promise<Map<string, string>> {
    const body = `<?xml version="1.0" encoding="UTF-8"?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:getetag/>
  </d:prop>
</d:propfind>`;

    const xml = await this.request(
      "PROPFIND",
      this.resolveUrl(calendarHref),
      body,
      1
    );
    const entries = parseMultistatus(xml);
    const etags = new Map<string, string>();

    for (const entry of entries) {
      const etag = entry.props["getetag"];
      // Skip the calendar collection itself (it has no etag or matches the calendar href)
      if (etag && entry.href !== calendarHref) {
        etags.set(entry.href, etag);
      }
    }

    return etags;
  }

  /**
   * Get the current RFC 6578 WebDAV-Sync `sync-token` for a calendar
   * collection via a depth-0 PROPFIND. Used ONLY to seed/refresh the token
   * this connector persists for `getCollectionChanges`'s fast path — never
   * to fetch changes themselves. Passing `syncToken: null` to
   * `getCollectionChanges` also returns a token, but the server computes it
   * by returning EVERY object in the collection, which is unbounded; this
   * PROPFIND is one cheap request regardless of collection size. Modeled on
   * `getCalendarCtag` (identical request/parsing shape — a single property
   * nested in one `<response>`, unlike the sync-collection REPORT's
   * `<sync-token>`, which is a direct child of `<multistatus>`).
   *
   * MEASURED (iCloud): the returned value happens to be byte-identical to
   * `getctag` today. That is an iCloud implementation coincidence, not a
   * spec guarantee — always fetch `sync-token` explicitly here rather than
   * substituting a cached ctag.
   */
  async getSyncToken(calendarHref: string): Promise<string | null> {
    const body = `<?xml version="1.0" encoding="UTF-8"?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:sync-token/>
  </d:prop>
</d:propfind>`;

    const xml = await this.request(
      "PROPFIND",
      this.resolveUrl(calendarHref),
      body,
      0
    );
    const entries = parseMultistatus(xml);

    for (const entry of entries) {
      if (entry.props["sync-token"]) return entry.props["sync-token"];
    }

    return null;
  }

  /**
   * Fetch incremental changes to a calendar collection via RFC 6578
   * WebDAV-Sync (a `sync-collection` REPORT). Unlike `getEventEtags`
   * (PROPFIND depth-1 over every event, every poll), this asks the server
   * to return only what changed since `syncToken`.
   *
   * Pass `null` for `syncToken` to request the full current state — an
   * initial or reset sync — sent as an empty `<A:sync-token/>` element per
   * RFC 6578 §3.2.
   *
   * The calendar collection's own href commonly appears in the delta (it
   * changed too, since a child changed) — this is filtered out and never
   * appears in `changed` or `deletedHrefs`. Deleted items are reported as a
   * bare 404 `<response>` with no `getetag`/`calendar-data`, so they're
   * classified here rather than via `parseEventResponses` (which requires
   * both and would silently drop them).
   *
   * If the server rejects the token as invalid/expired (RFC 6578 §3.7),
   * this throws `InvalidSyncTokenError` — callers should discard the stored
   * token and retry with `syncToken: null` for a full resync.
   */
  async getCollectionChanges(
    calendarHref: string,
    syncToken: string | null
  ): Promise<CalDAVCollectionChanges> {
    const tokenElement = syncToken
      ? `<A:sync-token>${escapeXml(syncToken)}</A:sync-token>`
      : `<A:sync-token/>`;

    const body = `<?xml version="1.0" encoding="UTF-8"?>
<A:sync-collection xmlns:A="DAV:">
  ${tokenElement}
  <A:sync-level>1</A:sync-level>
  <A:prop><A:getetag/></A:prop>
</A:sync-collection>`;

    const xml = await this.request(
      "REPORT",
      this.resolveUrl(calendarHref),
      body,
      1
    );

    return parseSyncCollectionResponse(xml, calendarHref);
  }

  /**
   * Fetch specific events by href using calendar-multiget REPORT.
   */
  async fetchEventsByHref(
    calendarHref: string,
    eventHrefs: string[]
  ): Promise<CalDAVEvent[]> {
    if (eventHrefs.length === 0) return [];

    const hrefElements = eventHrefs
      .map((href) => `    <d:href>${escapeXml(href)}</d:href>`)
      .join("\n");

    const body = `<?xml version="1.0" encoding="UTF-8"?>
<c:calendar-multiget xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:prop>
    <d:getetag/>
    <c:calendar-data/>
  </d:prop>
${hrefElements}
</c:calendar-multiget>`;

    const xml = await this.request(
      "REPORT",
      this.resolveUrl(calendarHref),
      body,
      1
    );
    return parseEventResponses(xml);
  }
  /**
   * Fetch a single event's ICS data by its href (GET), along with its
   * current etag so a subsequent `updateEventICS` write can pass it as
   * `If-Match` and detect a concurrent modification (see
   * {@link PreconditionFailedError}). The etag is unquoted here (the `ETag`
   * response header is normally quoted) for consistency with the etags
   * `parseMultistatus`'s `getetag` extraction produces elsewhere in this
   * file — `updateEventICS` re-adds the quotes when sending `If-Match`.
   */
  async fetchEventICS(
    eventHref: string
  ): Promise<{ icsData: string; etag: string | null } | null> {
    try {
      const response = await fetch(this.resolveUrl(eventHref), {
        method: "GET",
        headers: {
          Authorization: this.authHeader,
          Accept: "text/calendar",
        },
        redirect: "follow",
      });

      if (!response.ok) return null;
      const icsData = await response.text();
      const rawEtag = response.headers.get("ETag");
      return { icsData, etag: rawEtag ? rawEtag.replace(/"/g, "") : null };
    } catch {
      return null;
    }
  }

  /**
   * Update an event by PUTting modified ICS data back to its href.
   * Returns true on success. Throws {@link PreconditionFailedError} for a
   * `412` response (the `If-Match` etag is stale — a concurrent write raced
   * this one) so callers can distinguish "lost the race, retry" from any
   * other write failure, which still just resolves to `false` as before.
   */
  async updateEventICS(
    eventHref: string,
    icsData: string,
    etag?: string
  ): Promise<boolean> {
    const headers: Record<string, string> = {
      Authorization: this.authHeader,
      "Content-Type": "text/calendar; charset=utf-8",
    };
    // Use If-Match to prevent overwriting concurrent changes
    if (etag) {
      headers["If-Match"] = `"${etag}"`;
    }

    const response = await fetch(this.resolveUrl(eventHref), {
      method: "PUT",
      headers,
      body: icsData,
      redirect: "follow",
    });

    if (response.status === 412) {
      throw new PreconditionFailedError();
    }

    return response.ok || response.status === 204;
  }
}

// ---- XML Parsing Helpers ----

function escapeXml(str: string): string {
  return str
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/**
 * Extract text content from an XML tag, handling nested tags.
 * Returns the inner text of the first match.
 */
function extractTagContent(xml: string, tagName: string): string | null {
  // Match both prefixed (d:href, cs:getctag) and unprefixed tags
  // Also handle the tag appearing with various namespace prefixes
  const patterns = [
    // Exact tag with any prefix: <prefix:tagName>...</prefix:tagName>
    new RegExp(`<[^>]*?:${tagName}[^>]*>([\\s\\S]*?)</[^>]*?:${tagName}>`, "i"),
    // Unprefixed: <tagName>...</tagName>
    new RegExp(`<${tagName}[^>]*>([\\s\\S]*?)</${tagName}>`, "i"),
  ];

  for (const pattern of patterns) {
    const match = xml.match(pattern);
    if (match) return match[1].trim();
  }
  return null;
}

/**
 * Extract href from within a nested element (e.g., <d:current-user-principal><d:href>/path</d:href></d:current-user-principal>)
 */
function extractNestedHref(xml: string): string | null {
  const hrefMatch = xml.match(/<[^>]*?:?href[^>]*>([^<]+)<\/[^>]*?:?href>/i);
  return hrefMatch ? hrefMatch[1].trim() : null;
}

/**
 * Parse a CalDAV multistatus XML response into structured entries.
 */
function parseMultistatus(xml: string): MultistatusEntry[] {
  const entries: MultistatusEntry[] = [];

  // Split on response boundaries. iCloud returns the DAV: namespace as the
  // default (unprefixed) namespace — e.g. `<response xmlns="DAV:">` — while
  // other servers use a prefix (`<D:response>`). Match an OPTIONAL namespace
  // prefix; a required leading char would consume the "r" of an unprefixed
  // "response" and silently produce zero entries. The lookahead pins the tag
  // name so `<responses>`/substrings don't match, and the missing `/` branch
  // keeps closing tags out.
  const responseBlocks = xml.split(
    /<(?:[a-zA-Z][\w.-]*:)?response(?=[\s>/])[^>]*>/i
  );

  for (let i = 1; i < responseBlocks.length; i++) {
    const block = responseBlocks[i];
    const endIdx = block.search(/<\/[^>]*?response>/i);
    const responseXml = endIdx >= 0 ? block.substring(0, endIdx) : block;

    // Extract href
    const hrefMatch = responseXml.match(
      /<[^>]*?:?href[^>]*>([^<]+)<\/[^>]*?:?href>/i
    );
    if (!hrefMatch) continue;
    const href = hrefMatch[1].trim();

    const props: Record<string, string> = {};

    // Extract displayname
    const displayname = extractTagContent(responseXml, "displayname");
    if (displayname) props["displayname"] = displayname;

    // Extract getctag
    const ctag = extractTagContent(responseXml, "getctag");
    if (ctag) props["getctag"] = ctag;

    // Extract sync-token — used by getSyncToken's depth-0 PROPFIND, where
    // it's nested inside this single <response> like any other property
    // (same shape as getctag above). The sync-collection REPORT's
    // <sync-token> (parsed by parseSyncCollectionResponse, not here) is a
    // different shape: a direct child of <multistatus>, a SIBLING of every
    // <response> block rather than nested in one — extractTagContent(xml,
    // ...) on the whole document handles that case instead.
    const syncToken = extractTagContent(responseXml, "sync-token");
    if (syncToken) props["sync-token"] = syncToken;

    // Extract getetag
    const etag = extractTagContent(responseXml, "getetag");
    if (etag) props["getetag"] = etag.replace(/"/g, "");

    // Extract resourcetype (keep as raw XML for type checking)
    const resourceType = extractTagContent(responseXml, "resourcetype");
    if (resourceType) props["resourcetype"] = resourceType;

    // Extract calendar-data
    const calendarData = extractTagContent(responseXml, "calendar-data");
    if (calendarData) props["calendar-data"] = calendarData;

    // Extract current-user-principal (contains nested href)
    const principal = extractTagContent(
      responseXml,
      "current-user-principal"
    );
    if (principal) {
      const principalHref = extractNestedHref(principal);
      if (principalHref) props["current-user-principal"] = principalHref;
    }

    // Extract calendar-home-set (contains nested href)
    const homeSet = extractTagContent(responseXml, "calendar-home-set");
    if (homeSet) {
      const homeHref = extractNestedHref(homeSet);
      if (homeHref) props["calendar-home-set"] = homeHref;
    }

    // Extract supported-calendar-component-set
    const compSet = extractTagContent(
      responseXml,
      "supported-calendar-component-set"
    );
    if (compSet) props["supported-calendar-component-set"] = compSet;

    // Extract status
    const status = extractTagContent(responseXml, "status");

    entries.push({ href, props, status: status || undefined });
  }

  return entries;
}

/**
 * Parse event responses from a REPORT (calendar-query or calendar-multiget).
 */
function parseEventResponses(xml: string): CalDAVEvent[] {
  const entries = parseMultistatus(xml);
  const events: CalDAVEvent[] = [];

  for (const entry of entries) {
    const etag = entry.props["getetag"];
    const icsData = entry.props["calendar-data"];

    if (etag && icsData) {
      events.push({
        href: entry.href,
        etag,
        icsData,
      });
    }
  }

  return events;
}

/**
 * Detect the RFC 6578 §3.7 `DAV:valid-sync-token` precondition-failure body
 * (`<error><valid-sync-token/></error>`) inside a 403 response. Matches an
 * optional namespace prefix so both iCloud's unprefixed `<valid-sync-token/>`
 * and a prefixed `<D:valid-sync-token/>` are recognized — same rationale as
 * the `responseBlocks` split in `parseMultistatus`.
 */
function isInvalidSyncTokenResponse(xml: string): boolean {
  return /<(?:[a-zA-Z][\w.-]*:)?valid-sync-token(?=[\s/>])/i.test(xml);
}

/**
 * Normalize an href for equality comparisons by ensuring a trailing slash.
 * Calendar collection hrefs are conventionally slash-terminated, but this
 * guards against a caller-supplied href that omits it.
 */
function normalizeHref(href: string): string {
  return href.endsWith("/") ? href : `${href}/`;
}

/**
 * Parse a `sync-collection` REPORT response into changed/deleted hrefs plus
 * the new sync token.
 *
 * Three things make this different from `parseEventResponses`:
 *  - The sync token is a direct child of `<multistatus>` — a SIBLING of the
 *    `<response>` blocks, not nested inside one — so it's extracted from the
 *    whole document rather than from any per-response entry.
 *  - The collection itself shows up as one of the `<response>` entries
 *    (it "changed" because a child changed), carrying a real `getetag`. It's
 *    filtered out by comparing hrefs (trailing-slash normalized) against the
 *    requested collection href, rather than by a fragile `.ics` suffix check.
 *  - Deletions arrive as a bare `<status>HTTP/1.1 404 Not Found</status>`
 *    with no `<propstat>`/etag/calendar-data at all, so they're invisible to
 *    `parseEventResponses`'s `etag && icsData` filter. They're classified
 *    here directly from the response status instead.
 */
function parseSyncCollectionResponse(
  xml: string,
  collectionHref: string
): CalDAVCollectionChanges {
  const token = extractTagContent(xml, "sync-token") || "";
  const normalizedCollectionHref = normalizeHref(collectionHref);

  const changed: CalDAVCollectionChange[] = [];
  const deletedHrefs: string[] = [];

  for (const entry of parseMultistatus(xml)) {
    if (normalizeHref(entry.href) === normalizedCollectionHref) continue;

    if (entry.status && /\b404\b/.test(entry.status)) {
      deletedHrefs.push(entry.href);
      continue;
    }

    const etag = entry.props["getetag"];
    if (etag) {
      changed.push({ href: entry.href, etag });
    }
  }

  return { token, changed, deletedHrefs };
}

/**
 * Format a Date as CalDAV time-range string: YYYYMMDDTHHMMSSZ
 */
export function toCalDAVTimeString(date: Date): string {
  return date.toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
}
