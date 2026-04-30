/**
 * Minimal typed Airtable REST client.
 *
 * Covers the endpoints the connector needs: whoami, base/table metadata,
 * record list/patch, and webhook registration.
 *
 * Throttling: Airtable allows 5 req/sec per base. Each AirtableAPI instance
 * paces its own requests to stay just under that ceiling. 429s still get
 * retried with exponential backoff as a safety net.
 *
 * 401 responses are surfaced as AirtableAuthError so callers can stop
 * processing instead of spamming every record with the same revoked token.
 */

const API = "https://api.airtable.com";
const MIN_REQUEST_INTERVAL_MS = 220; // ~4.5 req/sec, under the 5 req/sec cap.
const MAX_429_RETRIES = 4;

export class AirtableAuthError extends Error {
  constructor(
    public readonly method: string,
    public readonly path: string,
    public readonly body: string
  ) {
    super(`Airtable ${method} ${path} failed: 401 ${body}`);
    this.name = "AirtableAuthError";
  }
}

export function isAirtableAuthError(error: unknown): error is AirtableAuthError {
  return error instanceof AirtableAuthError;
}

export class AirtableNotFoundError extends Error {
  constructor(
    public readonly method: string,
    public readonly path: string,
    public readonly body: string
  ) {
    super(`Airtable ${method} ${path} failed: 404 ${body}`);
    this.name = "AirtableNotFoundError";
  }
}

export function isAirtableNotFoundError(
  error: unknown
): error is AirtableNotFoundError {
  return error instanceof AirtableNotFoundError;
}

// ---- Response shapes ----

export type AirtableUserInfo = {
  id: string;
  email?: string;
  scopes?: string[];
};

export type AirtableBase = {
  id: string;
  name: string;
  permissionLevel: "none" | "read" | "comment" | "edit" | "create";
};

export type AirtableFieldType =
  | "singleLineText"
  | "multilineText"
  | "richText"
  | "email"
  | "phoneNumber"
  | "url"
  | "checkbox"
  | "date"
  | "dateTime"
  | "singleSelect"
  | "multipleSelects"
  | "singleCollaborator"
  | "multipleCollaborators"
  | "multipleRecordLinks"
  | "number"
  | "rating"
  | "currency"
  | "percent"
  | "duration"
  | "formula"
  | "rollup"
  | "lookup"
  | "count"
  | "createdTime"
  | "lastModifiedTime"
  | "createdBy"
  | "lastModifiedBy"
  | "autoNumber"
  | "barcode"
  | "button"
  | "externalSyncSource"
  | "multipleAttachments"
  | string;

export type AirtableSelectOption = {
  id: string;
  name: string;
  color?: string;
};

export type AirtableField = {
  id: string;
  name: string;
  type: AirtableFieldType;
  options?: {
    choices?: AirtableSelectOption[];
    linkedTableId?: string;
    [key: string]: unknown;
  };
};

export type AirtableTable = {
  id: string;
  name: string;
  primaryFieldId: string;
  fields: AirtableField[];
};

export type AirtableCollaborator = {
  id: string;
  email?: string;
  name?: string;
};

export type AirtableRecord = {
  id: string;
  createdTime: string;
  fields: Record<string, unknown>;
};

export type AirtableListRecords = {
  records: AirtableRecord[];
  offset?: string;
};

export type AirtableWebhook = {
  id: string;
  macSecretBase64: string;
  expirationTime?: string;
};

export type AirtableWebhookListItem = {
  id: string;
  notificationUrl?: string;
  expirationTime?: string;
  isHookEnabled?: boolean;
};

export type AirtableWebhookChangedRecord = {
  current?: { cellValuesByFieldId?: Record<string, unknown> };
  previous?: { cellValuesByFieldId?: Record<string, unknown> };
  unchanged?: { cellValuesByFieldId?: Record<string, unknown> };
};

export type AirtableWebhookTableChange = {
  changedRecordsById?: Record<string, AirtableWebhookChangedRecord>;
  createdRecordsById?: Record<
    string,
    { createdTime?: string; cellValuesByFieldId?: Record<string, unknown> }
  >;
  destroyedRecordIds?: string[];
  // Populated when a webhook subscribes to "tableFields". We don't parse
  // the contents — their presence alone is the signal to re-detect tables.
  changedFieldsById?: Record<string, unknown>;
  createdFieldsById?: Record<string, unknown>;
  destroyedFieldIds?: string[];
};

export type AirtableWebhookPayload = {
  timestamp: string;
  baseTransactionNumber?: number;
  changedTablesById?: Record<string, AirtableWebhookTableChange>;
};

export type AirtableWebhookPayloadsResponse = {
  payloads: AirtableWebhookPayload[];
  cursor: number;
  mightHaveMore: boolean;
  payloadFormat?: string;
};

// ---- Client ----

export class AirtableAPI {
  private lastRequestAt = 0;

  constructor(private readonly token: string) {}

  private async throttle(): Promise<void> {
    const now = Date.now();
    const wait = this.lastRequestAt + MIN_REQUEST_INTERVAL_MS - now;
    if (wait > 0) {
      await new Promise((r) => setTimeout(r, wait));
    }
    this.lastRequestAt = Date.now();
  }

  async whoami(): Promise<AirtableUserInfo> {
    return this.req<AirtableUserInfo>("GET", "/v0/meta/whoami");
  }

  async listBases(): Promise<AirtableBase[]> {
    const bases: AirtableBase[] = [];
    let offset: string | undefined;
    do {
      const url = `/v0/meta/bases${offset ? `?offset=${encodeURIComponent(offset)}` : ""}`;
      const res = await this.req<{ bases: AirtableBase[]; offset?: string }>(
        "GET",
        url
      );
      bases.push(...res.bases);
      offset = res.offset;
    } while (offset);
    return bases;
  }

  async listTables(baseId: string): Promise<AirtableTable[]> {
    const res = await this.req<{ tables: AirtableTable[] }>(
      "GET",
      `/v0/meta/bases/${baseId}/tables`
    );
    return res.tables;
  }

  async listRecords(
    baseId: string,
    tableId: string,
    opts: {
      offset?: string | null;
      pageSize?: number;
      fields?: string[];
      filterByFormula?: string;
    } = {}
  ): Promise<AirtableListRecords> {
    const params = new URLSearchParams();
    params.set("pageSize", String(opts.pageSize ?? 100));
    if (opts.offset) params.set("offset", opts.offset);
    if (opts.filterByFormula) params.set("filterByFormula", opts.filterByFormula);
    for (const f of opts.fields ?? []) params.append("fields[]", f);
    return this.req<AirtableListRecords>(
      "GET",
      `/v0/${baseId}/${tableId}?${params.toString()}`
    );
  }

  async getRecord(
    baseId: string,
    tableId: string,
    recordId: string
  ): Promise<AirtableRecord> {
    return this.req<AirtableRecord>(
      "GET",
      `/v0/${baseId}/${tableId}/${recordId}`
    );
  }

  async patchRecord(
    baseId: string,
    tableId: string,
    recordId: string,
    fields: Record<string, unknown>
  ): Promise<AirtableRecord> {
    return this.req<AirtableRecord>(
      "PATCH",
      `/v0/${baseId}/${tableId}/${recordId}`,
      { fields }
    );
  }

  async createWebhook(
    baseId: string,
    notificationUrl: string,
    spec: {
      options: {
        filters: {
          dataTypes: Array<"tableData" | "tableFields" | "tableMetadata">;
          recordChangeScope?: string;
        };
        includes?: {
          includeCellValuesInFieldIds?: "all" | string[];
          includePreviousCellValues?: boolean;
        };
      };
    }
  ): Promise<AirtableWebhook> {
    return this.req<AirtableWebhook>("POST", `/v0/bases/${baseId}/webhooks`, {
      notificationUrl,
      specification: spec,
    });
  }

  async listWebhooks(baseId: string): Promise<AirtableWebhookListItem[]> {
    const res = await this.req<{ webhooks?: AirtableWebhookListItem[] }>(
      "GET",
      `/v0/bases/${baseId}/webhooks`
    );
    return res.webhooks ?? [];
  }

  async deleteWebhook(baseId: string, webhookId: string): Promise<void> {
    await this.req<unknown>(
      "DELETE",
      `/v0/bases/${baseId}/webhooks/${webhookId}`
    );
  }

  /**
   * Extends a webhook's expiration by 7 days from now. Returns the new
   * expiration time. May return `expirationTime: null` for hooks that don't
   * expire (rare; defensive). Throws AirtableNotFoundError if the webhook
   * has already been deleted or aged out — callers should treat that as a
   * cue to recreate the webhook.
   */
  async refreshWebhook(
    baseId: string,
    webhookId: string
  ): Promise<{ expirationTime: string | null }> {
    return this.req<{ expirationTime: string | null }>(
      "POST",
      `/v0/bases/${baseId}/webhooks/${webhookId}/refresh`
    );
  }

  async listWebhookPayloads(
    baseId: string,
    webhookId: string,
    cursor: number
  ): Promise<AirtableWebhookPayloadsResponse> {
    const params = new URLSearchParams({ cursor: String(cursor), limit: "50" });
    return this.req<AirtableWebhookPayloadsResponse>(
      "GET",
      `/v0/bases/${baseId}/webhooks/${webhookId}/payloads?${params.toString()}`
    );
  }

  private async req<T>(
    method: string,
    path: string,
    body?: unknown
  ): Promise<T> {
    const run = async (): Promise<Response> => {
      await this.throttle();
      return fetch(`${API}${path}`, {
        method,
        headers: {
          Authorization: `Bearer ${this.token}`,
          ...(body ? { "Content-Type": "application/json" } : {}),
        },
        body: body ? JSON.stringify(body) : undefined,
      });
    };

    let res = await run();
    for (let attempt = 0; attempt < MAX_429_RETRIES && res.status === 429; attempt++) {
      // Honor Retry-After when the server gives it; otherwise exponential
      // backoff starting at 1s and capped at 30s. Airtable sometimes returns
      // fractional seconds in Retry-After, so parse as float.
      const retryAfter = Number(res.headers.get("Retry-After"));
      const base = Number.isFinite(retryAfter) && retryAfter > 0
        ? retryAfter * 1000
        : Math.min(1000 * 2 ** attempt, 30_000);
      await new Promise((r) => setTimeout(r, base));
      res = await run();
    }
    if (res.status === 401) {
      const text = await res.text().catch(() => "");
      throw new AirtableAuthError(method, path, text);
    }
    if (res.status === 404) {
      const text = await res.text().catch(() => "");
      throw new AirtableNotFoundError(method, path, text);
    }
    if (!res.ok) {
      const text = await res.text().catch(() => "");
      throw new Error(`Airtable ${method} ${path} failed: ${res.status} ${text}`);
    }
    if (res.status === 204) return undefined as unknown as T;
    return (await res.json()) as T;
  }
}
