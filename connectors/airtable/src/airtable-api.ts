/**
 * Minimal typed Airtable REST client.
 *
 * Covers the endpoints the connector needs: whoami, base/table metadata,
 * record list/patch, record comments CRUD, and webhook registration.
 * Handles 429 rate limiting with one retry after the service-specified delay.
 */

const API = "https://api.airtable.com";

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

export type AirtableCommentAuthor = {
  id: string;
  email: string;
  name?: string;
};

export type AirtableMentioned = Record<
  string,
  {
    type: "user" | "userGroup";
    id: string;
    displayName?: string;
    email?: string;
    name?: string;
  }
>;

export type AirtableComment = {
  id: string;
  author: AirtableCommentAuthor;
  text: string;
  createdTime: string;
  lastUpdatedTime: string | null;
  parentCommentId?: string;
  mentioned?: AirtableMentioned;
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
  constructor(private readonly token: string) {}

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

  async listComments(
    baseId: string,
    tableId: string,
    recordId: string
  ): Promise<AirtableComment[]> {
    const comments: AirtableComment[] = [];
    let offset: string | undefined;
    do {
      const params = new URLSearchParams({ pageSize: "100" });
      if (offset) params.set("offset", offset);
      const res = await this.req<{ comments: AirtableComment[]; offset?: string }>(
        "GET",
        `/v0/${baseId}/${tableId}/${recordId}/comments?${params.toString()}`
      );
      comments.push(...res.comments);
      offset = res.offset;
    } while (offset);
    return comments;
  }

  async createComment(
    baseId: string,
    tableId: string,
    recordId: string,
    body: { text: string; parentCommentId?: string }
  ): Promise<AirtableComment> {
    return this.req<AirtableComment>(
      "POST",
      `/v0/${baseId}/${tableId}/${recordId}/comments`,
      body
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
    const run = async (): Promise<Response> =>
      fetch(`${API}${path}`, {
        method,
        headers: {
          Authorization: `Bearer ${this.token}`,
          ...(body ? { "Content-Type": "application/json" } : {}),
        },
        body: body ? JSON.stringify(body) : undefined,
      });

    let res = await run();
    if (res.status === 429) {
      const retryAfter = Number(res.headers.get("Retry-After") ?? "1");
      await new Promise((r) => setTimeout(r, Math.max(1, retryAfter) * 1000));
      res = await run();
    }
    if (!res.ok) {
      const text = await res.text().catch(() => "");
      throw new Error(`Airtable ${method} ${path} failed: ${res.status} ${text}`);
    }
    if (res.status === 204) return undefined as unknown as T;
    return (await res.json()) as T;
  }
}
