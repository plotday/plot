// Fellow API types

export type FellowNote = {
  id: string;
  title: string | null;
  event_guid: string | null;
  event_start: string | null;
  event_end: string | null;
  event_is_all_day: boolean;
  recording_ids: string[];
  event_attendees?: Array<{ email: string | null }> | null;
  content_markdown?: string | null;
  created_at: string | null;
  updated_at: string | null;
};

export type FellowActionItem = {
  id: string;
  text: string;
  status: "Done" | "Archived" | "Incomplete";
  due_date: string | null;
  note_id: string | null;
  assignees: Array<{ id: string; full_name: string; email: string }>;
  completion_type: string | null;
  ai_detected: boolean;
};

type PageInfo = {
  cursor: string | null;
  page_size: number;
};

type PaginatedResponse<K extends string, T> = {
  [key in K]: {
    page_info: PageInfo;
    data: T[];
  };
};

type NotesResponse = PaginatedResponse<"notes", FellowNote>;
type ActionItemsResponse = PaginatedResponse<"action_items", FellowActionItem>;

export type ListNotesParams = {
  cursor?: string;
  pageSize?: number;
  updatedAtStart?: string;
  updatedAtEnd?: string;
  eventGuid?: string;
};

export type ListActionItemsParams = {
  cursor?: string;
  pageSize?: number;
  scope?: "assigned_to_me" | "assigned_to_others" | "all";
  completed?: boolean;
  archived?: boolean;
};

/**
 * Payload Fellow POSTs to the webhook URL for `ai_note.generated` /
 * `ai_note.shared_to_channel` events. Carries the AI-generated notes content
 * directly via `ai_notes` — this is the ONLY place that content is available.
 * The `/notes` list endpoint's `content_markdown` field renders the note's
 * agenda/manual content but never includes the AI-generated summary, so
 * consumers must read `ai_notes` from this payload rather than re-fetching
 * the note via the API. `id` is the note id (matches `FellowNote.id`);
 * `event_id` is the calendar event identifier (matches `FellowNote.event_guid`).
 */
export type FellowAiNoteWebhook = {
  event_type: "ai_note.generated" | "ai_note.shared_to_channel";
  id: string;
  event_id: string | null;
  event_title: string | null;
  event_start: string | null;
  recap_url: string | null;
  ai_notes: string | null;
};

/**
 * Payload Fellow POSTs to the webhook URL for an `action_item.assigned`
 * event. Unlike `ai_note.*` events, this carries the full action item —
 * including `note_id`, which is `null` for a standalone action item created
 * directly in Fellow (not attached to a meeting note).
 */
export type FellowActionItemAssignedWebhook = {
  event_type: "action_item.assigned";
  id: string;
  text: string;
  assignees: Array<{ id: string; full_name: string; email: string }>;
  completion_type: string | null;
  status: FellowActionItem["status"];
  due_date: string | null;
  note_id: string | null;
  ai_generated: boolean;
  created_at: string;
  updated_at: string;
};

/** Payload Fellow POSTs to the webhook URL for an `action_item.completed` event. */
export type FellowActionItemCompletedWebhook = {
  event_type: "action_item.completed";
  id: string;
  text: string;
  assignee_id: string | null;
  assignee_name: string | null;
  assignee_email: string | null;
  note_id: string | null;
  due_date: string | null;
  done: boolean;
  wont_do: boolean;
  ai_generated: boolean;
};

export class FellowAPI {
  private baseUrl: string;

  constructor(
    private apiKey: string,
    subdomain: string,
  ) {
    this.baseUrl = `https://${subdomain}.fellow.app/api/v1`;
  }

  private async request<T>(endpoint: string, body?: unknown): Promise<T> {
    const response = await fetch(`${this.baseUrl}${endpoint}`, {
      method: "POST",
      headers: {
        "X-API-KEY": this.apiKey,
        "Content-Type": "application/json",
      },
      body: body ? JSON.stringify(body) : undefined,
    });

    if (!response.ok) {
      const text = await response.text().catch(() => "");
      throw new Error(
        `Fellow API error ${response.status}: ${response.statusText}${text ? ` - ${text}` : ""}`,
      );
    }

    // Some endpoints (e.g. complete/archive) return no body on success;
    // JSON.parse("") would throw, so treat an empty body as `undefined`
    // rather than a malformed response.
    const text = await response.text();
    return (text ? JSON.parse(text) : undefined) as T;
  }

  async listNotes(params?: ListNotesParams): Promise<{
    data: FellowNote[];
    nextCursor: string | null;
  }> {
    const body: Record<string, unknown> = {
      pagination: {
        cursor: params?.cursor ?? null,
        page_size: params?.pageSize ?? 50,
      },
      include: {
        event_attendees: true,
        content_markdown: true,
      },
      filters: {
        ...(params?.updatedAtStart
          ? { updated_at_start: params.updatedAtStart }
          : {}),
        ...(params?.updatedAtEnd
          ? { updated_at_end: params.updatedAtEnd }
          : {}),
        ...(params?.eventGuid ? { event_guid: params.eventGuid } : {}),
      },
    };

    const result = await this.request<NotesResponse>("/notes", body);
    return {
      data: result.notes.data,
      nextCursor: result.notes.page_info.cursor,
    };
  }

  async listActionItems(params?: ListActionItemsParams): Promise<{
    data: FellowActionItem[];
    nextCursor: string | null;
  }> {
    const body: Record<string, unknown> = {
      pagination: {
        cursor: params?.cursor ?? null,
        page_size: params?.pageSize ?? 50,
      },
      filters: {
        ...(params?.scope ? { scope: params.scope } : {}),
        ...(params?.completed !== undefined
          ? { completed: params.completed }
          : {}),
        ...(params?.archived !== undefined
          ? { archived: params.archived }
          : {}),
      },
    };

    const result = await this.request<ActionItemsResponse>(
      "/action_items",
      body,
    );
    return {
      data: result.action_items.data,
      nextCursor: result.action_items.page_info.cursor,
    };
  }

  /** Marks an action item done (`completed: true`) or reopens it (`false`). */
  async completeActionItem(id: string, completed: boolean): Promise<void> {
    await this.request<void>(`/action_item/${id}/complete`, { completed });
  }

  /** Archives an action item (marks it "won't do"). Not reversible via the API. */
  async archiveActionItem(id: string): Promise<void> {
    await this.request<void>(`/action_item/${id}/archive`);
  }

  async createWebhook(
    url: string,
    events: string[],
  ): Promise<{ id: string; secret: string }> {
    const result = await this.request<{
      webhook: { id: string; secret: string };
    }>("/webhook", {
      url,
      enabled_events: events,
      status: "active",
    });
    return result.webhook;
  }
}
