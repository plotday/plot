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

    return response.json() as Promise<T>;
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
