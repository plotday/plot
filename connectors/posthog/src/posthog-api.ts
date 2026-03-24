export class PostHogAPI {
  constructor(
    private apiKey: string,
    private projectId: string,
    private host: string
  ) {}

  private async request<T>(
    path: string,
    params?: Record<string, string>
  ): Promise<T> {
    const url = new URL(
      `/api/projects/${this.projectId}${path}`,
      this.host
    );
    if (params) {
      for (const [k, v] of Object.entries(params)) {
        url.searchParams.set(k, v);
      }
    }
    const response = await fetch(url.toString(), {
      headers: { Authorization: `Bearer ${this.apiKey}` },
    });
    if (!response.ok) {
      throw new Error(
        `PostHog API error: ${response.status} ${response.statusText}`
      );
    }
    return response.json() as Promise<T>;
  }

  async getEventDefinitions(): Promise<
    Array<{ name: string; volume_30_day: number | null }>
  > {
    const data = await this.request<{
      results: Array<{ name: string; volume_30_day: number | null }>;
    }>("/event_definitions/");
    return data.results;
  }

  async getEvents(
    eventName: string,
    after?: string
  ): Promise<{
    results: Array<{
      uuid: string;
      event: string;
      distinct_id: string;
      properties: Record<string, unknown>;
      timestamp: string;
      person?: { properties?: Record<string, unknown> };
    }>;
    next?: string;
  }> {
    const params: Record<string, string> = {
      event: eventName,
      limit: "100",
    };
    if (after) params.after = after;
    return this.request("/events/", params);
  }
}
