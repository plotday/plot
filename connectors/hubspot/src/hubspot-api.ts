// ---- HubSpot API Types ----

/**
 * Object types this connector reads. CRM records (contacts, companies,
 * deals) become threads; engagements (notes, tasks) become notes on their
 * associated records' threads.
 */
export type HubSpotRecordType = "contacts" | "companies" | "deals";
export type HubSpotEngagementType = "notes" | "tasks";
export type HubSpotObjectType = HubSpotRecordType | HubSpotEngagementType;

/**
 * A CRM object as returned by the v3 objects API. `properties` values are
 * always strings (HubSpot serializes numbers/dates/enums to strings) or
 * null when unset.
 */
export type HubSpotObject = {
  id: string;
  properties: Record<string, string | null>;
  createdAt: string;
  updatedAt: string;
  archived?: boolean;
  associations?: Record<
    string,
    { results: Array<{ id: string; type: string }> }
  >;
};

/** Cursor-paged response shape shared by list and search endpoints. */
export type HubSpotPage<T> = {
  results: T[];
  paging?: { next?: { after: string } };
};

/**
 * A HubSpot user who can own CRM records. `id` is the owner id (the value
 * of `hubspot_owner_id` properties); `userId` is the account user id (the
 * value of `hs_created_by_user_id` properties). Both identify the same
 * person, so the connector indexes its owner map by both.
 */
export type HubSpotOwner = {
  id: string;
  email: string | null;
  firstName: string | null;
  lastName: string | null;
  userId: number | null;
  archived: boolean;
};

export type HubSpotPipelineStage = {
  id: string;
  label: string;
  displayOrder: number;
  /**
   * Stage metadata. `probability` is "1.0" for closed-won and "0.0" for
   * closed-lost; `isClosed` is the string "true" for both terminal stages.
   */
  metadata?: { isClosed?: string | boolean; probability?: string };
};

export type HubSpotPipeline = {
  id: string;
  label: string;
  displayOrder: number;
  stages: HubSpotPipelineStage[];
};

/**
 * OAuth token introspection result. `hub_id` is the portal id used in app
 * URLs and as the workspace qualifier in `source` keys; `hub_domain` is a
 * human-readable portal identifier (e.g. "acme.hubspot.com"); `user` is
 * the connecting user's email.
 */
export type HubSpotTokenInfo = {
  hub_id: number;
  hub_domain: string;
  user: string;
  user_id: number;
  scopes: string[];
};

/**
 * HUBSPOT_DEFINED association type ids for note → record associations,
 * used when creating a note engagement attached to a CRM record. See
 * HubSpot's "association type ID values" reference.
 */
export const NOTE_ASSOCIATION_TYPE_IDS: Record<HubSpotRecordType, number> = {
  contacts: 202,
  companies: 190,
  deals: 214,
};

/** Properties requested for each object type on list/search/batch reads. */
export const OBJECT_PROPERTIES: Record<HubSpotObjectType, string[]> = {
  contacts: [
    "firstname",
    "lastname",
    "email",
    "phone",
    "jobtitle",
    "createdate",
    "lastmodifieddate",
    "hubspot_owner_id",
    "hs_created_by_user_id",
  ],
  companies: [
    "name",
    "domain",
    "createdate",
    "hs_lastmodifieddate",
    "hubspot_owner_id",
    "hs_created_by_user_id",
  ],
  deals: [
    "dealname",
    "amount",
    "deal_currency_code",
    "dealstage",
    "pipeline",
    "closedate",
    "createdate",
    "hs_lastmodifieddate",
    "hubspot_owner_id",
    "hs_created_by_user_id",
  ],
  notes: [
    "hs_note_body",
    "hs_timestamp",
    "hs_lastmodifieddate",
    "hubspot_owner_id",
    "hs_created_by_user_id",
  ],
  tasks: [
    "hs_task_subject",
    "hs_task_body",
    "hs_task_status",
    "hs_timestamp",
    "hs_lastmodifieddate",
    "hubspot_owner_id",
    "hs_created_by_user_id",
  ],
};

/**
 * The last-modified property to filter incremental polls on. Contacts use
 * the legacy `lastmodifieddate` name; every other object uses
 * `hs_lastmodifieddate`.
 */
export const LAST_MODIFIED_PROPERTY: Record<HubSpotObjectType, string> = {
  contacts: "lastmodifieddate",
  companies: "hs_lastmodifieddate",
  deals: "hs_lastmodifieddate",
  notes: "hs_lastmodifieddate",
  tasks: "hs_lastmodifieddate",
};

// ---- API Client ----

export class HubSpotAPI {
  private readonly baseUrl = "https://api.hubapi.com";

  constructor(private readonly accessToken: string) {}

  private async request<T>(
    method: string,
    path: string,
    body?: unknown
  ): Promise<T> {
    const response = await fetch(`${this.baseUrl}${path}`, {
      method,
      headers: {
        Authorization: `Bearer ${this.accessToken}`,
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
    });

    if (!response.ok) {
      const text = await response.text();
      // Carry the HTTP status so callers can branch on expected failures
      // (e.g. 404 for a record deleted upstream) without string matching.
      throw Object.assign(
        new Error(
          `HubSpot API ${method} ${path} failed (${response.status}): ${text}`
        ),
        { status: response.status }
      );
    }

    if (response.status === 204) return undefined as T;
    return (await response.json()) as T;
  }

  /**
   * Introspect the access token to identify the connected portal and user.
   * (This endpoint takes the token in the path, not the auth header.)
   */
  async getAccessTokenInfo(): Promise<HubSpotTokenInfo> {
    return this.request(
      "GET",
      `/oauth/v1/access-tokens/${encodeURIComponent(this.accessToken)}`
    );
  }

  /**
   * List a page of objects with cursor paging. `associations` adds each
   * result's associated record ids (used for engagements to find their
   * parent records).
   */
  async listObjects(
    objectType: HubSpotObjectType,
    options?: {
      after?: string | null;
      limit?: number;
      properties?: string[];
      associations?: string[];
    }
  ): Promise<HubSpotPage<HubSpotObject>> {
    const params = new URLSearchParams();
    if (options?.limit) params.set("limit", String(options.limit));
    if (options?.after) params.set("after", options.after);
    if (options?.properties?.length) {
      params.set("properties", options.properties.join(","));
    }
    if (options?.associations?.length) {
      params.set("associations", options.associations.join(","));
    }
    const qs = params.toString();
    return this.request(
      "GET",
      `/crm/v3/objects/${objectType}${qs ? `?${qs}` : ""}`
    );
  }

  /**
   * Search objects modified at or after `since`, ordered oldest-first so
   * callers can advance a high-water mark safely even when they stop
   * before the last page. Search pages max out at 200 results and the
   * endpoint caps any query at 10,000 total results — the poll loop
   * re-queries with an advanced `since` rather than paging past the cap.
   */
  async searchModifiedSince(
    objectType: HubSpotObjectType,
    options: {
      since: Date;
      after?: string | null;
      limit?: number;
      properties?: string[];
    }
  ): Promise<HubSpotPage<HubSpotObject>> {
    const property = LAST_MODIFIED_PROPERTY[objectType];
    const body: Record<string, unknown> = {
      filterGroups: [
        {
          filters: [
            {
              propertyName: property,
              operator: "GTE",
              value: String(options.since.getTime()),
            },
          ],
        },
      ],
      sorts: [{ propertyName: property, direction: "ASCENDING" }],
      properties: options.properties ?? [],
      limit: options.limit ?? 100,
    };
    if (options.after) body.after = options.after;
    return this.request(
      "POST",
      `/crm/v3/objects/${objectType}/search`,
      body
    );
  }

  /** Get a single object by id. Throws with `status: 404` when deleted. */
  async getObject(
    objectType: HubSpotObjectType,
    objectId: string,
    properties?: string[],
    associations?: string[]
  ): Promise<HubSpotObject> {
    const params = new URLSearchParams();
    if (properties?.length) params.set("properties", properties.join(","));
    if (associations?.length) {
      params.set("associations", associations.join(","));
    }
    const qs = params.toString();
    return this.request(
      "GET",
      `/crm/v3/objects/${objectType}/${objectId}${qs ? `?${qs}` : ""}`
    );
  }

  /**
   * Batch-read objects by id (up to 100 per call). Ids deleted upstream
   * are silently absent from `results` — callers treat missing ids as
   * deleted records.
   */
  async batchReadObjects(
    objectType: HubSpotObjectType,
    ids: string[],
    properties?: string[]
  ): Promise<HubSpotObject[]> {
    if (!ids.length) return [];
    const result = await this.request<{ results: HubSpotObject[] }>(
      "POST",
      `/crm/v3/objects/${objectType}/batch/read`,
      {
        properties: properties ?? [],
        inputs: ids.map((id) => ({ id })),
      }
    );
    return result.results ?? [];
  }

  /** Update an object's properties. */
  async updateObject(
    objectType: HubSpotObjectType,
    objectId: string,
    properties: Record<string, string>
  ): Promise<HubSpotObject> {
    return this.request(
      "PATCH",
      `/crm/v3/objects/${objectType}/${objectId}`,
      { properties }
    );
  }

  /**
   * Create a note engagement associated with a CRM record. `body` is HTML
   * (`hs_note_body`); the association uses the HUBSPOT_DEFINED note →
   * record association type for the parent's object type.
   */
  async createNote(
    body: string,
    timestamp: Date,
    parentType: HubSpotRecordType,
    parentId: string
  ): Promise<HubSpotObject> {
    return this.request("POST", "/crm/v3/objects/notes", {
      properties: {
        hs_note_body: body,
        hs_timestamp: timestamp.toISOString(),
      },
      associations: [
        {
          to: { id: parentId },
          types: [
            {
              associationCategory: "HUBSPOT_DEFINED",
              associationTypeId: NOTE_ASSOCIATION_TYPE_IDS[parentType],
            },
          ],
        },
      ],
    });
  }

  /** List all owners (paged internally). Used for author attribution. */
  async listAllOwners(): Promise<HubSpotOwner[]> {
    const owners: HubSpotOwner[] = [];
    let after: string | undefined;
    do {
      const params = new URLSearchParams({ limit: "100" });
      if (after) params.set("after", after);
      const page = await this.request<HubSpotPage<HubSpotOwner>>(
        "GET",
        `/crm/v3/owners/?${params.toString()}`
      );
      owners.push(...(page.results ?? []));
      after = page.paging?.next?.after;
    } while (after);
    return owners;
  }

  /** List an object type's pipelines with their stages. */
  async listPipelines(
    objectType: "deals"
  ): Promise<HubSpotPipeline[]> {
    const result = await this.request<{ results: HubSpotPipeline[] }>(
      "GET",
      `/crm/v3/pipelines/${objectType}`
    );
    return result.results ?? [];
  }
}

// ---- Value helpers ----

/** Join first/last name, falling back through email to a placeholder. */
export function contactDisplayName(
  properties: Record<string, string | null>
): string {
  const name = [properties.firstname, properties.lastname]
    .filter(Boolean)
    .join(" ");
  return name || properties.email || "Unknown Contact";
}

/**
 * Format a deal amount for the preview line, e.g. "USD 12,500". Returns
 * null when the deal has no amount set.
 */
export function formatDealAmount(
  properties: Record<string, string | null>
): string | null {
  const raw = properties.amount;
  if (raw == null || raw === "") return null;
  const amount = Number(raw);
  if (!Number.isFinite(amount)) return null;
  const currency = properties.deal_currency_code;
  const formatted = amount.toLocaleString("en-US");
  return currency ? `${currency} ${formatted}` : formatted;
}

/** Escape text for embedding in an HTML note body. */
export function escapeHtml(text: string): string {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/**
 * Convert plain text (with newlines) to minimal HTML for `hs_note_body`.
 * HubSpot stores note bodies as HTML, where literal newlines collapse.
 */
export function plainTextToHtml(text: string): string {
  return escapeHtml(text).replace(/\n/g, "<br>");
}
