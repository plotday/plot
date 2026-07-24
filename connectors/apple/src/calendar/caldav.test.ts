import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import {
  AuthenticationError,
  CalDAVClient,
  InvalidSyncTokenError,
  PreconditionFailedError,
} from "./caldav";

/** Minimal fetch Response stand-in — only the members CalDAVClient reads. */
function mockResponse(status: number, body: string): Response {
  return {
    status,
    ok: status >= 200 && status < 300,
    statusText: "",
    text: async () => body,
  } as unknown as Response;
}

function makeClient(): CalDAVClient {
  return new CalDAVClient({ appleId: "me@icloud.com", appPassword: "app-pw" });
}

describe("CalDAVClient.getCollectionChanges", () => {
  let fetchMock: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  // Verbatim (measured) iCloud response for a sync-collection REPORT with no
  // changes: zero <response> elements, and <sync-token> is a direct child of
  // <multistatus> — a sibling of any response blocks, not nested in one.
  const EMPTY_DELTA_XML = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<multistatus xmlns="DAV:">
 <sync-token>HwoQEgwAAEtvRDAmkwAAAAAYARgAIhUI7YrB98zK+bIDEJml3pqc7L7MhgEoAA==</sync-token>
</multistatus>`;

  it("parses an empty-delta response as zero changed, zero deleted, with the token extracted", async () => {
    fetchMock.mockResolvedValue(mockResponse(207, EMPTY_DELTA_XML));
    const client = makeClient();

    const result = await client.getCollectionChanges(
      "/289842362/calendars/work/",
      "some-prior-token"
    );

    expect(result.changed).toEqual([]);
    expect(result.deletedHrefs).toEqual([]);
    expect(result.token).toBe(
      "HwoQEgwAAEtvRDAmkwAAAAAYARgAIhUI7YrB98zK+bIDEJml3pqc7L7MhgEoAA=="
    );
  });

  it("classifies a mixed unprefixed response: .ics change -> changed, 404 -> deletedHrefs, collection's own href -> neither", async () => {
    // Modeled on the measured iCloud response for a poll where an event was
    // added/modified and a probe event was deleted. iCloud's default
    // (unprefixed) DAV: namespace is used throughout, exactly as observed:
    // <response xmlns="DAV:">, not <D:response>. The first <response> block
    // below — the calendar COLLECTION's own href, carrying a getetag — is
    // copied verbatim from the measured payload; it must be filtered out,
    // not treated as a changed event. The genuine changed-event block
    // (a real .ics href with a getetag) follows the same shape but was not
    // itself part of the pasted probe transcript (that probe's add+delete
    // happened to collapse into a single collection-level entry plus one
    // 404) — it's synthesized here from the identical response shape so the
    // "changed" classification path has real coverage.
    const MIXED_XML = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<multistatus xmlns="DAV:">
<response xmlns="DAV:">
 <href>/289842362/calendars/work/</href>
 <propstat><prop><getetag xmlns="DAV:">"ldp3blyq"</getetag></prop>
 <status>HTTP/1.1 200 OK</status></propstat>
</response>
<response xmlns="DAV:">
 <href>/289842362/calendars/work/new-event-abc123.ics</href>
 <propstat><prop><getetag xmlns="DAV:">"xyz789"</getetag></prop>
 <status>HTTP/1.1 200 OK</status></propstat>
</response>
<response xmlns="DAV:">
 <href>/289842362/calendars/work/plot-sync-probe-97471.ics</href>
 <status>HTTP/1.1 404 Not Found</status>
</response>
<sync-token>HwoQEgwAAEtvRDAmkwAAAAAYARgAIhUI7YrB98zK+bIDEJml3pqc7L7MhgEoAQ==</sync-token>
</multistatus>`;
    fetchMock.mockResolvedValue(mockResponse(207, MIXED_XML));
    const client = makeClient();

    const result = await client.getCollectionChanges(
      "/289842362/calendars/work/",
      "some-prior-token"
    );

    expect(result.changed).toEqual([
      { href: "/289842362/calendars/work/new-event-abc123.ics", etag: "xyz789" },
    ]);
    expect(result.deletedHrefs).toEqual([
      "/289842362/calendars/work/plot-sync-probe-97471.ics",
    ]);
    // The collection's own href must not appear on either side.
    const allHrefs = [
      ...result.changed.map((c) => c.href),
      ...result.deletedHrefs,
    ];
    expect(allHrefs).not.toContain("/289842362/calendars/work/");
    expect(result.token).toBe(
      "HwoQEgwAAEtvRDAmkwAAAAAYARgAIhUI7YrB98zK+bIDEJml3pqc7L7MhgEoAQ=="
    );
  });

  it("parses a prefixed (<D:response>) sync-collection response identically", async () => {
    const PREFIXED_XML = `<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
<D:response>
<D:href>/cal/collection/changed-event.ics</D:href>
<D:propstat><D:prop><D:getetag>"etag-prefixed-1"</D:getetag></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
</D:response>
<D:response>
<D:href>/cal/collection/removed-event.ics</D:href>
<D:status>HTTP/1.1 404 Not Found</D:status>
</D:response>
<D:sync-token>opaque-prefixed-token-1</D:sync-token>
</D:multistatus>`;
    fetchMock.mockResolvedValue(mockResponse(207, PREFIXED_XML));
    const client = makeClient();

    const result = await client.getCollectionChanges("/cal/collection/", "prior-token");

    expect(result.changed).toEqual([
      { href: "/cal/collection/changed-event.ics", etag: "etag-prefixed-1" },
    ]);
    expect(result.deletedHrefs).toEqual(["/cal/collection/removed-event.ics"]);
    expect(result.token).toBe("opaque-prefixed-token-1");
  });

  it("surfaces a 403 + <valid-sync-token/> body as InvalidSyncTokenError", async () => {
    // Measured verbatim from iCloud (RFC 6578 §3.7 precondition failure),
    // both for a garbage token and for a valid-shaped-but-wrong token.
    const INVALID_TOKEN_XML = `<?xml version='1.0' encoding='UTF-8'?>
<error xmlns='DAV:'>
<valid-sync-token/>
</error>`;
    fetchMock.mockResolvedValue(mockResponse(403, INVALID_TOKEN_XML));
    const client = makeClient();

    await expect(
      client.getCollectionChanges("/289842362/calendars/work/", "garbage-token")
    ).rejects.toBeInstanceOf(InvalidSyncTokenError);
  });

  it("FIX 5: a 403 that is not a valid-sync-token rejection surfaces as AuthenticationError, not InvalidSyncTokenError", async () => {
    fetchMock.mockResolvedValue(mockResponse(403, ""));
    const client = makeClient();

    await expect(
      client.getCollectionChanges("/289842362/calendars/work/", "some-token")
    ).rejects.not.toBeInstanceOf(InvalidSyncTokenError);
    await expect(
      client.getCollectionChanges("/289842362/calendars/work/", "some-token")
    ).rejects.toBeInstanceOf(AuthenticationError);
  });

  it("FIX 5: a 401 surfaces as AuthenticationError (distinguishable so pollForChanges can log-and-reschedule instead of paging)", async () => {
    fetchMock.mockResolvedValue(mockResponse(401, ""));
    const client = makeClient();

    await expect(
      client.getCollectionChanges("/289842362/calendars/work/", "some-token")
    ).rejects.toBeInstanceOf(AuthenticationError);
  });

  it("sends an empty <A:sync-token/> element when the token is null (initial/reset sync)", async () => {
    fetchMock.mockResolvedValue(mockResponse(207, EMPTY_DELTA_XML));
    const client = makeClient();

    await client.getCollectionChanges("/289842362/calendars/work/", null);

    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [, options] = fetchMock.mock.calls[0] as [string, RequestInit];
    const body = options.body as string;
    expect(body).toContain("<A:sync-token/>");
    expect(body).not.toMatch(/<A:sync-token>[^/]/);
  });
});

describe("CalDAVClient.getSyncToken", () => {
  let fetchMock: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("extracts the sync-token from a depth-0 PROPFIND response, nested in a single <response> like getctag", async () => {
    const PROPFIND_XML = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<multistatus xmlns="DAV:">
<response>
 <href>/289842362/calendars/work/</href>
 <propstat>
  <prop>
   <sync-token>HwoQEgwAAEtvRDAmkwAAAAAYARgAIhUI7YrB98zK+bIDEJml3pqc7L7MhgEoAA==</sync-token>
  </prop>
  <status>HTTP/1.1 200 OK</status>
 </propstat>
</response>
</multistatus>`;
    fetchMock.mockResolvedValue(mockResponse(207, PROPFIND_XML));
    const client = makeClient();

    const token = await client.getSyncToken("/289842362/calendars/work/");

    expect(token).toBe(
      "HwoQEgwAAEtvRDAmkwAAAAAYARgAIhUI7YrB98zK+bIDEJml3pqc7L7MhgEoAA=="
    );
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [, options] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect((options.headers as Record<string, string>)["Depth"]).toBe("0");
    expect(options.body as string).toContain("<d:sync-token/>");
  });

  it("parses a prefixed (<D:sync-token>) response identically", async () => {
    const PROPFIND_XML = `<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
<D:response>
<D:href>/cal/collection/</D:href>
<D:propstat><D:prop><D:sync-token>opaque-prefixed-token-1</D:sync-token></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
</D:response>
</D:multistatus>`;
    fetchMock.mockResolvedValue(mockResponse(207, PROPFIND_XML));
    const client = makeClient();

    const token = await client.getSyncToken("/cal/collection/");

    expect(token).toBe("opaque-prefixed-token-1");
  });

  it("returns null when no response carries a sync-token", async () => {
    const EMPTY_XML = `<?xml version="1.0" encoding="UTF-8"?>
<multistatus xmlns="DAV:"></multistatus>`;
    fetchMock.mockResolvedValue(mockResponse(207, EMPTY_XML));
    const client = makeClient();

    const token = await client.getSyncToken("/289842362/calendars/work/");

    expect(token).toBeNull();
  });
});

describe("CalDAVClient.fetchEventICS / updateEventICS — etag + If-Match", () => {
  let fetchMock: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  /** Response stand-in that also carries a headers.get("ETag"), unlike the
   *  bare `mockResponse` helper above (which none of those tests need). */
  function icsResponse(
    status: number,
    body: string,
    etag: string | null
  ): Response {
    return {
      status,
      ok: status >= 200 && status < 300,
      statusText: "",
      text: async () => body,
      headers: { get: (name: string) => (name === "ETag" ? etag : null) },
    } as unknown as Response;
  }

  it("fetchEventICS returns the ICS body with the etag unquoted", async () => {
    fetchMock.mockResolvedValue(
      icsResponse(200, "BEGIN:VCALENDAR\r\nEND:VCALENDAR", '"abc123"')
    );
    const client = makeClient();

    const result = await client.fetchEventICS("/cal/evt-1.ics");

    expect(result).toEqual({
      icsData: "BEGIN:VCALENDAR\r\nEND:VCALENDAR",
      etag: "abc123",
    });
  });

  it("fetchEventICS returns a null etag when the server sends none", async () => {
    fetchMock.mockResolvedValue(icsResponse(200, "BEGIN:VCALENDAR", null));
    const client = makeClient();

    const result = await client.fetchEventICS("/cal/evt-1.ics");

    expect(result).toEqual({ icsData: "BEGIN:VCALENDAR", etag: null });
  });

  it("fetchEventICS returns null on a non-ok response", async () => {
    fetchMock.mockResolvedValue(icsResponse(404, "", null));
    const client = makeClient();

    expect(await client.fetchEventICS("/cal/evt-1.ics")).toBeNull();
  });

  it("updateEventICS sends the given etag as a quoted If-Match header", async () => {
    fetchMock.mockResolvedValue(icsResponse(204, "", null));
    const client = makeClient();

    await client.updateEventICS(
      "/cal/evt-1.ics",
      "BEGIN:VCALENDAR\r\nEND:VCALENDAR",
      "abc123"
    );

    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [, options] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect((options.headers as Record<string, string>)["If-Match"]).toBe(
      '"abc123"'
    );
  });

  it("updateEventICS omits If-Match when no etag is given (unchanged behavior)", async () => {
    fetchMock.mockResolvedValue(icsResponse(204, "", null));
    const client = makeClient();

    await client.updateEventICS(
      "/cal/evt-1.ics",
      "BEGIN:VCALENDAR\r\nEND:VCALENDAR"
    );

    const [, options] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(
      (options.headers as Record<string, string>)["If-Match"]
    ).toBeUndefined();
  });

  it("updateEventICS throws PreconditionFailedError on a 412 response", async () => {
    fetchMock.mockResolvedValue(icsResponse(412, "", null));
    const client = makeClient();

    await expect(
      client.updateEventICS(
        "/cal/evt-1.ics",
        "BEGIN:VCALENDAR\r\nEND:VCALENDAR",
        "stale-etag"
      )
    ).rejects.toBeInstanceOf(PreconditionFailedError);
  });

  it("updateEventICS still resolves to false (not throw) for a generic non-412 failure", async () => {
    fetchMock.mockResolvedValue(icsResponse(500, "", null));
    const client = makeClient();

    await expect(
      client.updateEventICS(
        "/cal/evt-1.ics",
        "BEGIN:VCALENDAR\r\nEND:VCALENDAR",
        "abc123"
      )
    ).resolves.toBe(false);
  });

  it("updateEventICS resolves true on 204 and on 200", async () => {
    const client = makeClient();

    fetchMock.mockResolvedValue(icsResponse(204, "", null));
    expect(await client.updateEventICS("/cal/evt-1.ics", "ICS")).toBe(true);

    fetchMock.mockResolvedValue(icsResponse(200, "", null));
    expect(await client.updateEventICS("/cal/evt-1.ics", "ICS")).toBe(true);
  });
});

describe("CalDAVClient.listCalendarsByComponent", () => {
  let fetchMock: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  const HOME_XML = `<?xml version="1.0" encoding="UTF-8"?>
<multistatus xmlns="DAV:">
<response>
 <href>/289842362/calendars/work/</href>
 <propstat><prop>
  <displayname>Work</displayname>
  <resourcetype><collection/><calendar xmlns="urn:ietf:params:xml:ns:caldav"/></resourcetype>
  <supported-calendar-component-set xmlns="urn:ietf:params:xml:ns:caldav"><comp name="VEVENT"/></supported-calendar-component-set>
 </prop><status>HTTP/1.1 200 OK</status></propstat>
</response>
<response>
 <href>/289842362/tasks/home/</href>
 <propstat><prop>
  <displayname>Reminders</displayname>
  <resourcetype><collection/><calendar xmlns="urn:ietf:params:xml:ns:caldav"/></resourcetype>
  <supported-calendar-component-set xmlns="urn:ietf:params:xml:ns:caldav"><comp name="VTODO"/></supported-calendar-component-set>
 </prop><status>HTTP/1.1 200 OK</status></propstat>
</response>
</multistatus>`;

  it("returns only VTODO collections when filtering for VTODO", async () => {
    fetchMock.mockResolvedValue(mockResponse(207, HOME_XML));
    const client = makeClient();

    const lists = await client.listCalendarsByComponent(
      "/289842362/",
      "VTODO"
    );

    expect(lists).toEqual([
      { href: "/289842362/tasks/home/", displayName: "Reminders", ctag: null },
    ]);
  });

  it("returns only VEVENT collections when filtering for VEVENT (existing listCalendars behavior)", async () => {
    fetchMock.mockResolvedValue(mockResponse(207, HOME_XML));
    const client = makeClient();

    const calendars = await client.listCalendars("/289842362/");

    expect(calendars).toEqual([
      { href: "/289842362/calendars/work/", displayName: "Work", ctag: null },
    ]);
  });
});

describe("CalDAVClient.fetchTodos", () => {
  let fetchMock: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("sends a VTODO comp-filter with no time-range and parses the returned resources", async () => {
    const REPORT_XML = `<?xml version="1.0" encoding="UTF-8"?>
<multistatus xmlns="DAV:">
<response>
 <href>/289842362/tasks/home/abc-123.ics</href>
 <propstat><prop>
  <getetag>"etag-1"</getetag>
  <calendar-data xmlns="urn:ietf:params:xml:ns:caldav">BEGIN:VCALENDAR
END:VCALENDAR</calendar-data>
 </prop><status>HTTP/1.1 200 OK</status></propstat>
</response>
</multistatus>`;
    fetchMock.mockResolvedValue(mockResponse(207, REPORT_XML));
    const client = makeClient();

    const resources = await client.fetchTodos("/289842362/tasks/home/");

    expect(resources).toEqual([
      {
        href: "/289842362/tasks/home/abc-123.ics",
        etag: "etag-1",
        icsData: "BEGIN:VCALENDAR\nEND:VCALENDAR",
      },
    ]);

    const [, , sentBody] = fetchMock.mock.calls[0];
    // sentBody is undefined here — fetch's signature is (url, init); assert on init.body instead:
    const init = fetchMock.mock.calls[0][1] as { body: string };
    expect(init.body).toContain('<c:comp-filter name="VTODO"/>');
    expect(init.body).not.toContain("time-range");
  });
});

describe("CalDAVClient.discoverDefaultTasksListHref", () => {
  let fetchMock: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("returns the href when the server advertises a default tasks list", async () => {
    const XML = `<?xml version="1.0" encoding="UTF-8"?>
<multistatus xmlns="DAV:">
<response>
 <href>/289842362/</href>
 <propstat><prop>
  <schedule-default-tasks-URL xmlns="urn:ietf:params:xml:ns:caldav"><href>/289842362/tasks/home/</href></schedule-default-tasks-URL>
 </prop><status>HTTP/1.1 200 OK</status></propstat>
</response>
</multistatus>`;
    fetchMock.mockResolvedValue(mockResponse(207, XML));
    const client = makeClient();

    const href = await client.discoverDefaultTasksListHref("/289842362/");
    expect(href).toBe("/289842362/tasks/home/");
  });

  it("returns null when the property is absent (degrade to opt-in-only)", async () => {
    const XML = `<?xml version="1.0" encoding="UTF-8"?>
<multistatus xmlns="DAV:">
<response><href>/289842362/</href><propstat><prop/><status>HTTP/1.1 404 Not Found</status></propstat></response>
</multistatus>`;
    fetchMock.mockResolvedValue(mockResponse(207, XML));
    const client = makeClient();

    expect(await client.discoverDefaultTasksListHref("/289842362/")).toBeNull();
  });
});
