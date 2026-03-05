const NOTION_API = "https://api.notion.com/v1";
const NOTION_VERSION = "2022-06-28";

// --- Types ---

export type NotionPage = {
  id: string;
  object: "page";
  parent:
    | { type: "workspace"; workspace: true }
    | { type: "page_id"; page_id: string }
    | { type: "database_id"; database_id: string };
  url: string;
  created_time: string;
  last_edited_time: string;
  created_by: { id: string; object: "user" };
  last_edited_by: { id: string; object: "user" };
  archived: boolean;
  properties: {
    title?: {
      type: "title";
      title: Array<{ plain_text: string }>;
    };
    [key: string]: any;
  };
  icon: { type: string; emoji?: string } | null;
};

export type NotionComment = {
  id: string;
  object: "comment";
  parent: { type: "page_id"; page_id: string } | { type: "block_id"; block_id: string };
  discussion_id: string;
  created_time: string;
  last_edited_time: string;
  created_by: { id: string; object: "user" };
  rich_text: Array<{ plain_text: string; href?: string | null }>;
};

export type NotionUser = {
  id: string;
  object: "user";
  type?: "person" | "bot";
  name: string | null;
  avatar_url: string | null;
  person?: { email?: string };
};

export type SyncState = {
  channelId: string;
  lastPollTime?: string;
  pageToken?: string;
  batchNumber: number;
};

// --- API Client ---

export class NotionApi {
  constructor(public accessToken: string) {}

  async call(
    method: string,
    url: string,
    body?: Record<string, any>
  ): Promise<any> {
    const headers: Record<string, string> = {
      Authorization: `Bearer ${this.accessToken}`,
      "Notion-Version": NOTION_VERSION,
      Accept: "application/json",
      ...(body ? { "Content-Type": "application/json" } : {}),
    };

    const response = await fetch(url, {
      method,
      headers,
      ...(body ? { body: JSON.stringify(body) } : {}),
    });

    if (!response.ok) {
      if (response.status === 401) {
        throw new Error("Authentication failed - token may be expired");
      }
      if (response.status === 429) {
        throw new Error("Rate limited by Notion API");
      }
      const text = await response.text();
      throw new Error(`Notion API error (${response.status}): ${text}`);
    }

    return await response.json();
  }
}

// --- API Functions ---

/**
 * Search for all pages accessible to the integration.
 * Returns pages sorted by last_edited_time descending.
 */
export async function searchPages(
  api: NotionApi,
  options?: {
    cursor?: string;
    sortDirection?: "ascending" | "descending";
    lastEditedAfter?: string;
  }
): Promise<{ pages: NotionPage[]; nextCursor: string | null }> {
  const body: Record<string, any> = {
    filter: { property: "object", value: "page" },
    page_size: 100,
    sort: {
      direction: options?.sortDirection ?? "descending",
      timestamp: "last_edited_time",
    },
  };

  if (options?.cursor) {
    body.start_cursor = options.cursor;
  }

  const data = await api.call("POST", `${NOTION_API}/search`, body);

  return {
    pages: data.results as NotionPage[],
    nextCursor: data.has_more ? data.next_cursor : null,
  };
}

/**
 * Retrieve a single page by ID.
 */
export async function getPage(
  api: NotionApi,
  pageId: string
): Promise<NotionPage> {
  return (await api.call(
    "GET",
    `${NOTION_API}/pages/${pageId}`
  )) as NotionPage;
}

/**
 * List comments on a block or page (paginated).
 */
export async function listComments(
  api: NotionApi,
  blockId: string,
  cursor?: string
): Promise<{ comments: NotionComment[]; nextCursor: string | null }> {
  const params = new URLSearchParams({
    block_id: blockId,
    page_size: "100",
  });
  if (cursor) {
    params.set("start_cursor", cursor);
  }

  const data = await api.call(
    "GET",
    `${NOTION_API}/comments?${params}`
  );

  return {
    comments: data.results as NotionComment[],
    nextCursor: data.has_more ? data.next_cursor : null,
  };
}

/**
 * Fetch all comments on a page (auto-paginate).
 */
export async function listAllComments(
  api: NotionApi,
  blockId: string
): Promise<NotionComment[]> {
  const allComments: NotionComment[] = [];
  let cursor: string | undefined;

  do {
    const result = await listComments(api, blockId, cursor);
    allComments.push(...result.comments);
    cursor = result.nextCursor ?? undefined;
  } while (cursor);

  return allComments;
}

/**
 * Create a comment on a page.
 */
export async function createComment(
  api: NotionApi,
  pageId: string,
  content: string
): Promise<NotionComment> {
  return (await api.call("POST", `${NOTION_API}/comments`, {
    parent: { page_id: pageId },
    rich_text: [{ type: "text", text: { content } }],
  })) as NotionComment;
}

/**
 * Get user details by ID.
 */
export async function getUser(
  api: NotionApi,
  userId: string
): Promise<NotionUser> {
  return (await api.call(
    "GET",
    `${NOTION_API}/users/${userId}`
  )) as NotionUser;
}

// --- Helpers ---

/**
 * Extract plain text title from a Notion page's properties.
 */
export function getPageTitle(page: NotionPage): string {
  // Try the "title" property first
  if (page.properties.title?.title) {
    return page.properties.title.title.map((t) => t.plain_text).join("") || "Untitled";
  }

  // Search all properties for a title-type property
  for (const prop of Object.values(page.properties)) {
    if (prop?.type === "title" && prop.title) {
      return prop.title.map((t: { plain_text: string }) => t.plain_text).join("") || "Untitled";
    }
  }

  return "Untitled";
}

/**
 * Extract plain text from Notion rich_text array.
 */
export function richTextToPlain(richText: Array<{ plain_text: string }>): string {
  return richText.map((t) => t.plain_text).join("");
}
