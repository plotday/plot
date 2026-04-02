// ---- Attio API Types ----

export type AttioRecordId = {
  record_id: string;
  object_id: string;
  workspace_id: string;
};

export type AttioAttributeValue = {
  active_from: string | null;
  active_until: string | null;
  attribute_type: string;
  // Text / number
  value?: unknown;
  // Name fields
  first_name?: string;
  last_name?: string;
  full_name?: string;
  // Email
  original_email_address?: string;
  email_address?: string;
  email_domain?: string;
  // Phone
  phone_number?: string;
  // Domain
  domain?: string;
  // Currency
  currency_value?: number;
  currency_code?: string;
  // Select / status
  option?: { id: { option_id: string }; title: string };
  status?: { id: { status_id: string }; title: string };
  // Record reference
  target_object?: string;
  target_record_id?: string;
  // Actor reference
  referenced_actor_type?: string;
  referenced_actor_id?: string;
};

export type AttioRecord = {
  id: AttioRecordId;
  values: Record<string, AttioAttributeValue[]>;
  created_at: string;
};

export type AttioTask = {
  id: { task_id: string; workspace_id: string };
  content_plaintext: string;
  assignees: Array<{
    referenced_actor_type: string;
    referenced_actor_id: string;
  }>;
  is_completed: boolean;
  deadline_at: string | null;
  created_at: string;
  linked_records: Array<{
    target_object: string;
    target_record_id: string;
  }>;
};

export type AttioPaginatedResponse<T> = {
  data: T[];
  next_cursor: string | null;
};

export type AttioSelectOption = {
  id: { option_id: string };
  title: string;
};

export type AttioStatusOption = {
  id: { status_id: string };
  title: string;
  is_archived: boolean;
};

export type AttioWebhookSubscription = {
  event_type: string;
  filter?: {
    $or?: Array<{
      $and: Array<{
        field: string;
        operator: string;
        value: string;
      }>;
    }>;
  } | null;
};

export type AttioWebhookEvent = {
  event_type: string;
  object?: { id: { object_id: string }; slug?: string };
  record?: AttioRecord;
  task?: AttioTask;
};

// ---- Value Extraction Helpers ----

/** Get the current (active) value entry from an attribute array. */
export function currentValue(
  entries: AttioAttributeValue[] | undefined
): AttioAttributeValue | undefined {
  if (!entries?.length) return undefined;
  return entries.find((e) => e.active_until === null) ?? entries[0];
}

/** Extract a simple text/number value from an attribute. */
export function extractTextValue(
  values: Record<string, AttioAttributeValue[]>,
  key: string
): string | undefined {
  const entry = currentValue(values[key]);
  if (entry?.value == null) return undefined;
  return String(entry.value);
}

/** Extract the deal/company name (simple text attribute). */
export function extractName(
  values: Record<string, AttioAttributeValue[]>
): string {
  return extractTextValue(values, "name") ?? "";
}

/** Extract a person's full name from first_name + last_name. */
export function extractPersonName(
  values: Record<string, AttioAttributeValue[]>
): string {
  const entry = currentValue(values["name"]);
  if (!entry) return "";
  if (entry.full_name) return entry.full_name;
  return [entry.first_name, entry.last_name].filter(Boolean).join(" ");
}

/** Extract the primary email address. */
export function extractEmail(
  values: Record<string, AttioAttributeValue[]>
): string | undefined {
  return currentValue(values["email_addresses"])?.email_address ?? undefined;
}

/** Extract the primary phone number. */
export function extractPhone(
  values: Record<string, AttioAttributeValue[]>
): string | undefined {
  return currentValue(values["phone_numbers"])?.phone_number ?? undefined;
}

/** Extract the deal stage (select/status attribute). */
export function extractDealStage(
  values: Record<string, AttioAttributeValue[]>
): { id: string; title: string } | undefined {
  const entry = currentValue(values["stage"]);
  if (entry?.status) {
    return { id: entry.status.id.status_id, title: entry.status.title };
  }
  if (entry?.option) {
    return { id: entry.option.id.option_id, title: entry.option.title };
  }
  return undefined;
}

/** Extract currency value from the deal. */
export function extractCurrencyValue(
  values: Record<string, AttioAttributeValue[]>
): { amount: number; currency: string } | undefined {
  const entry = currentValue(values["value"]);
  if (entry?.currency_value == null) return undefined;
  return {
    amount: entry.currency_value,
    currency: entry.currency_code ?? "USD",
  };
}

/** Extract the primary domain from a company record. */
export function extractDomain(
  values: Record<string, AttioAttributeValue[]>
): string | undefined {
  return currentValue(values["domains"])?.domain ?? undefined;
}

/** Extract the owner/assignee actor reference. */
export function extractOwner(
  values: Record<string, AttioAttributeValue[]>
): { actorType: string; actorId: string } | undefined {
  const entry = currentValue(values["owner"]);
  if (!entry?.referenced_actor_id) return undefined;
  return {
    actorType: entry.referenced_actor_type ?? "workspace-member",
    actorId: entry.referenced_actor_id,
  };
}

// ---- API Client ----

export class AttioAPI {
  private readonly baseUrl = "https://api.attio.com/v2";

  constructor(private readonly apiKey: string) {}

  private async request<T>(
    method: string,
    path: string,
    body?: unknown
  ): Promise<T> {
    const response = await fetch(`${this.baseUrl}${path}`, {
      method,
      headers: {
        Authorization: `Bearer ${this.apiKey}`,
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
    });

    if (!response.ok) {
      const text = await response.text();
      throw new Error(
        `Attio API ${method} ${path} failed (${response.status}): ${text}`
      );
    }

    if (response.status === 204) return undefined as T;
    return (await response.json()) as T;
  }

  /** Get the current workspace info via /v2/self. */
  async getWorkspace(): Promise<{ name: string }> {
    // /v2/self returns { workspace_id, token_id } — no workspace name.
    const self = await this.request<{
      workspace_id: string;
      token_id: string;
    }>("GET", "/self");

    // Try to get a friendly name from workspace members (requires user_management:read)
    try {
      const members = await this.request<{
        data: Array<{
          first_name: string;
          last_name: string;
          email_address: string;
        }>;
      }>("GET", "/workspace_members");
      const first = members?.data?.[0];
      if (first) {
        const name = [first.first_name, first.last_name]
          .filter(Boolean)
          .join(" ");
        if (name) return { name };
      }
    } catch {
      // Missing scope or other error — fall through
    }

    return { name: self.workspace_id };
  }

  /** Query records for a given object type (deals, people, companies). */
  async queryRecords(
    objectSlug: string,
    options?: {
      cursor?: string;
      limit?: number;
      filter?: unknown;
      sorts?: unknown;
    }
  ): Promise<AttioPaginatedResponse<AttioRecord>> {
    const body: Record<string, unknown> = {};
    if (options?.filter) body.filter = options.filter;
    if (options?.sorts) body.sorts = options.sorts;
    if (options?.limit) body.limit = options.limit;
    if (options?.cursor) body.offset = options.cursor;
    return this.request("POST", `/objects/${objectSlug}/records/query`, body);
  }

  /** Get a single record by ID. */
  async getRecord(
    objectSlug: string,
    recordId: string
  ): Promise<{ data: AttioRecord }> {
    return this.request("GET", `/objects/${objectSlug}/records/${recordId}`);
  }

  /** Update a record's attribute values. */
  async updateRecord(
    objectSlug: string,
    recordId: string,
    values: Record<string, unknown>
  ): Promise<{ data: AttioRecord }> {
    return this.request(
      "PATCH",
      `/objects/${objectSlug}/records/${recordId}`,
      { data: { values } }
    );
  }

  /** Query tasks. */
  async queryTasks(options?: {
    cursor?: string;
    limit?: number;
  }): Promise<AttioPaginatedResponse<AttioTask>> {
    const body: Record<string, unknown> = {};
    if (options?.limit) body.limit = options.limit;
    if (options?.cursor) body.offset = options.cursor;
    return this.request("POST", "/tasks/query", body);
  }

  /** Create a note on a record. */
  async createNote(
    parentObject: string,
    parentRecordId: string,
    title: string,
    content: string
  ): Promise<{ data: { id: { note_id: string } } }> {
    return this.request("POST", "/notes", {
      data: {
        parent_object: parentObject,
        parent_record_id: parentRecordId,
        title: title || undefined,
        content_plaintext: content,
      },
    });
  }

  /** Create a webhook subscription. */
  async createWebhook(
    targetUrl: string,
    subscriptions: AttioWebhookSubscription[]
  ): Promise<{ data: { id: { webhook_id: string } } }> {
    return this.request("POST", "/webhooks", {
      data: { target_url: targetUrl, subscriptions },
    });
  }

  /** Delete a webhook. */
  async deleteWebhook(webhookId: string): Promise<void> {
    return this.request("DELETE", `/webhooks/${webhookId}`);
  }

  /** Get select/status options for an attribute on an object. */
  async getSelectOptions(
    objectSlug: string,
    attributeSlug: string
  ): Promise<AttioSelectOption[]> {
    const result = await this.request<{
      data: Array<{ id: { option_id: string }; title: string }>;
    }>(
      "GET",
      `/objects/${objectSlug}/attributes/${attributeSlug}/options`
    );
    return result.data ?? [];
  }

  /** Get status options for a status-type attribute. */
  async getStatusOptions(
    objectSlug: string,
    attributeSlug: string
  ): Promise<AttioStatusOption[]> {
    const result = await this.request<{
      data: AttioStatusOption[];
    }>(
      "GET",
      `/objects/${objectSlug}/attributes/${attributeSlug}/statuses`
    );
    return result.data ?? [];
  }
}
