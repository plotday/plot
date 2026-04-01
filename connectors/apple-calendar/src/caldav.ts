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
      // Only include entries that are calendars (have <c:calendar/> in resourcetype)
      const resourceType = entry.props["resourcetype"] || "";
      if (!resourceType.includes("calendar")) continue;
      // Skip VTODO-only or VJOURNAL-only collections
      if (resourceType.includes("vevent") === false && resourceType.includes("calendar") && entry.props["supported-calendar-component-set"]?.includes("VEVENT") === false) {
        // If supported-calendar-component-set is available and doesn't include VEVENT, skip.
        // But if it's not available, include (most calendars support VEVENT).
        if (entry.props["supported-calendar-component-set"]) continue;
      }

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
   * Fetch a single event's ICS data by its href (GET).
   */
  async fetchEventICS(eventHref: string): Promise<string | null> {
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
      return await response.text();
    } catch {
      return null;
    }
  }

  /**
   * Update an event by PUTting modified ICS data back to its href.
   * Returns true on success.
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

  // Split on response boundaries — handle various namespace prefixes
  const responseBlocks = xml.split(/<[^/][^>]*?response[^>]*>/i);

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
 * Format a Date as CalDAV time-range string: YYYYMMDDTHHMMSSZ
 */
export function toCalDAVTimeString(date: Date): string {
  return date.toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
}
