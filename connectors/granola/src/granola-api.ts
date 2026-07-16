// Granola public API types and client
// API reference: https://docs.granola.ai/api-reference

export type GranolaUser = {
  name: string | null;
  email: string;
};

export type GranolaCalendarInvitee = {
  email: string;
  name?: string | null;
  response_status?: string | null;
};

export type GranolaCalendarEvent = {
  event_title: string | null;
  calendar_event_id: string | null;
  scheduled_start_time: string | null;
  scheduled_end_time: string | null;
  organiser: string | null;
  invitees: GranolaCalendarInvitee[] | null;
};

export type GranolaNoteSummary = {
  id: string;
  object: "note";
  title: string | null;
  owner: GranolaUser;
  created_at: string;
  updated_at: string;
};

export type GranolaNote = GranolaNoteSummary & {
  web_url: string;
  calendar_event: GranolaCalendarEvent | null;
  attendees: GranolaUser[];
  summary_text: string;
  summary_markdown: string | null;
};

export type ListNotesParams = {
  cursor?: string | null;
  pageSize?: number;
  updatedAfter?: string;
  createdAfter?: string;
  createdBefore?: string;
};

/** Error from the Granola API carrying the HTTP status for classification. */
export class GranolaApiError extends Error {
  constructor(
    message: string,
    public readonly status: number
  ) {
    super(message);
    this.name = "GranolaApiError";
  }
}

export class GranolaAPI {
  private baseUrl = "https://public-api.granola.ai/v1";

  constructor(private apiKey: string) {}

  private async request<T>(path: string, init?: RequestInit): Promise<T> {
    const response = await fetch(`${this.baseUrl}${path}`, {
      ...init,
      headers: {
        Authorization: `Bearer ${this.apiKey}`,
        Accept: "application/json",
        ...(init?.headers ?? {}),
      },
    });

    if (!response.ok) {
      const body = await response.text().catch(() => "");
      throw new GranolaApiError(
        `Granola API ${response.status} ${response.statusText} on ${path}${body ? ` — ${body}` : ""}`,
        response.status
      );
    }

    return response.json() as Promise<T>;
  }

  async listNotes(params?: ListNotesParams): Promise<{
    data: GranolaNoteSummary[];
    cursor: string | null;
    hasMore: boolean;
  }> {
    const search = new URLSearchParams();
    if (params?.cursor) search.set("cursor", params.cursor);
    if (params?.pageSize !== undefined)
      search.set("page_size", String(params.pageSize));
    if (params?.updatedAfter) search.set("updated_after", params.updatedAfter);
    if (params?.createdAfter) search.set("created_after", params.createdAfter);
    if (params?.createdBefore)
      search.set("created_before", params.createdBefore);

    const qs = search.toString();
    const result = await this.request<{
      notes: GranolaNoteSummary[];
      cursor: string | null;
      hasMore: boolean;
    }>(`/notes${qs ? `?${qs}` : ""}`);
    return {
      data: result.notes,
      cursor: result.cursor,
      hasMore: result.hasMore,
    };
  }

  async getNote(noteId: string): Promise<GranolaNote> {
    return this.request<GranolaNote>(`/notes/${encodeURIComponent(noteId)}`);
  }
}
