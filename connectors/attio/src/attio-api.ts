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

/**
 * The actor that created an entity (note, task, record). `type` is one of
 * `workspace-member`, `system`, `api-token`, `app`; only `workspace-member`
 * maps to a human author. Both fields are nullable in Attio's schema.
 */
export type AttioActor = {
  type: string | null;
  id: string | null;
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
  /** The actor that created this task (used for author attribution). */
  created_by_actor?: AttioActor;
  linked_records: Array<{
    target_object: string;
    target_record_id: string;
  }>;
};

export type AttioNote = {
  id: { note_id: string; workspace_id: string };
  parent_object: string;
  parent_record_id: string;
  title: string;
  content_plaintext: string;
  created_by_actor: AttioActor;
  created_at: string;
};

/**
 * A member of the Attio workspace. `id.workspace_member_id` is the actor id
 * carried by `created_by_actor` / `created_by` for `workspace-member` actors,
 * so it's the key to resolve an actor id back to a real person.
 */
export type AttioWorkspaceMember = {
  id: { workspace_id: string; workspace_member_id: string };
  first_name: string | null;
  last_name: string | null;
  avatar_url: string | null;
  email_address: string | null;
  access_level?: string;
  created_at?: string;
};

/**
 * Attio's list/query endpoints paginate with `limit`/`offset` only — the
 * response body carries just `data`, no cursor. Callers detect the end of
 * the collection by receiving a partial (or empty) page.
 */
export type AttioPaginatedResponse<T> = {
  data: T[];
};

export type AttioObject = {
  id: { object_id: string; workspace_id: string };
  api_slug: string;
  singular_noun?: string;
  plural_noun?: string;
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

/**
 * One event inside a webhook delivery. Attio sends only ids — never the
 * full record/note/task object — so handlers must fetch the entity by id.
 * Which id fields are present depends on `event_type` (`record.*` events
 * carry `object_id` + `record_id`, `note.*` carry `note_id`, `task.*`
 * carry `task_id`).
 */
export type AttioWebhookEvent = {
  event_type: string;
  id: {
    workspace_id: string;
    object_id?: string;
    record_id?: string;
    note_id?: string;
    task_id?: string;
  };
  parent_object_id?: string;
  parent_record_id?: string;
  actor?: { type: string; id: string };
};

/**
 * The body Attio POSTs to a webhook target: events arrive batched, not one
 * per delivery.
 */
export type AttioWebhookPayload = {
  webhook_id: string;
  events: AttioWebhookEvent[];
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

/**
 * Extract the record creator from the `created_by` system attribute (an
 * actor-reference every Attio object carries). Returns the actor that
 * created the record — NOT the person a "people" record describes — so it's
 * the right source for the thread's author.
 */
export function extractCreatedByActor(
  values: Record<string, AttioAttributeValue[]>
): { actorType: string; actorId: string } | undefined {
  const entry = currentValue(values["created_by"]);
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
      // Carry the HTTP status so callers can branch on expected failures
      // (e.g. 404 for a record deleted upstream) without string matching.
      throw Object.assign(
        new Error(
          `Attio API ${method} ${path} failed (${response.status}): ${text}`
        ),
        { status: response.status }
      );
    }

    if (response.status === 204) return undefined as T;
    return (await response.json()) as T;
  }

  /** Get the current workspace info via /v2/self. */
  async getWorkspace(): Promise<{ id: string; name: string; slug: string }> {
    const self = await this.request<{
      workspace_id: string;
      workspace_name: string;
      workspace_slug: string;
    }>("GET", "/self");

    return {
      id: self.workspace_id,
      name: self.workspace_name || self.workspace_id,
      slug: self.workspace_slug,
    };
  }

  /**
   * Query records for a given object type. `objectSlug` may be the slug
   * ("people") or the object's UUID — Attio accepts either in the path.
   */
  async queryRecords(
    objectSlug: string,
    options?: {
      offset?: number;
      limit?: number;
      filter?: unknown;
      sorts?: unknown;
    }
  ): Promise<AttioPaginatedResponse<AttioRecord>> {
    const body: Record<string, unknown> = {};
    if (options?.filter) body.filter = options.filter;
    if (options?.sorts) body.sorts = options.sorts;
    if (options?.limit) body.limit = options.limit;
    if (options?.offset != null) body.offset = options.offset;
    return this.request("POST", `/objects/${objectSlug}/records/query`, body);
  }

  /** List the workspace's objects (standard and custom). */
  async listObjects(): Promise<AttioObject[]> {
    const result = await this.request<{ data: AttioObject[] }>(
      "GET",
      "/objects"
    );
    return result.data ?? [];
  }

  /**
   * List the workspace's members. Used to resolve `workspace-member` actor
   * ids (from `created_by_actor` / `created_by`) to real people for author
   * attribution. Requires the `user_management:read` scope.
   */
  async listWorkspaceMembers(): Promise<AttioWorkspaceMember[]> {
    const result = await this.request<{ data: AttioWorkspaceMember[] }>(
      "GET",
      "/workspace_members"
    );
    return result.data ?? [];
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
    return this.request("PATCH", `/objects/${objectSlug}/records/${recordId}`, {
      data: { values },
    });
  }

  /** List tasks. */
  async queryTasks(options?: {
    offset?: number;
    limit?: number;
  }): Promise<AttioPaginatedResponse<AttioTask>> {
    const params = new URLSearchParams();
    if (options?.limit) params.set("limit", String(options.limit));
    if (options?.offset != null) params.set("offset", String(options.offset));
    const qs = params.toString();
    return this.request("GET", `/tasks${qs ? `?${qs}` : ""}`);
  }

  /** Get a single task by ID. */
  async getTask(taskId: string): Promise<{ data: AttioTask }> {
    return this.request("GET", `/tasks/${taskId}`);
  }

  /** List notes. */
  async queryNotes(options?: {
    offset?: number;
    limit?: number;
  }): Promise<AttioPaginatedResponse<AttioNote>> {
    const params = new URLSearchParams();
    if (options?.limit) params.set("limit", String(options.limit));
    if (options?.offset != null) params.set("offset", String(options.offset));
    const qs = params.toString();
    return this.request("GET", `/notes${qs ? `?${qs}` : ""}`);
  }

  /** Get a single note by ID. */
  async getNote(noteId: string): Promise<{ data: AttioNote }> {
    return this.request("GET", `/notes/${noteId}`);
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
        title: title || "Comment from Plot",
        format: "plaintext",
        content,
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
    }>("GET", `/objects/${objectSlug}/attributes/${attributeSlug}/options`);
    return result.data ?? [];
  }

  /** Get status options for a status-type attribute. */
  async getStatusOptions(
    objectSlug: string,
    attributeSlug: string
  ): Promise<AttioStatusOption[]> {
    const result = await this.request<{
      data: AttioStatusOption[];
    }>("GET", `/objects/${objectSlug}/attributes/${attributeSlug}/statuses`);
    return result.data ?? [];
  }
}
