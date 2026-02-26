import type {
  NewLinkWithNotes,
  NewActor,
} from "@plotday/twister/plot";

export type GmailLabel = {
  id: string;
  name: string;
  type: "system" | "user";
  messageListVisibility?: string;
  labelListVisibility?: string;
  messagesTotal?: number;
  messagesUnread?: number;
};

export type GmailThread = {
  id: string;
  historyId: string;
  messages: GmailMessage[];
};

export type GmailMessage = {
  id: string;
  threadId: string;
  labelIds: string[];
  snippet: string;
  historyId: string;
  internalDate: string;
  payload: GmailMessagePart;
  sizeEstimate: number;
};

export type GmailMessagePart = {
  partId?: string;
  mimeType: string;
  filename?: string;
  headers: GmailHeader[];
  body?: {
    attachmentId?: string;
    size: number;
    data?: string;
  };
  parts?: GmailMessagePart[];
};

export type GmailHeader = {
  name: string;
  value: string;
};

export type EmailAddress = {
  name: string | null;
  email: string;
};

export type SyncState = {
  channelId: string;
  pageToken?: string;
  historyId?: string;
  lastSyncTime?: Date;
  watchExpiration?: Date;
};

export class GmailApi {
  private baseUrl = "https://gmail.googleapis.com/gmail/v1/users/me";

  constructor(public accessToken: string) {}

  public async call(
    endpoint: string,
    options?: {
      method?: string;
      params?: { [key: string]: any };
      body?: any;
    }
  ): Promise<any> {
    const method = options?.method || "GET";
    const params = options?.params || {};
    const body = options?.body;

    // Build URL with query parameters
    const url = new URL(`${this.baseUrl}${endpoint}`);
    Object.entries(params).forEach(([key, value]) => {
      if (value !== undefined && value !== null) {
        url.searchParams.append(key, String(value));
      }
    });

    const headers: HeadersInit = {
      Authorization: `Bearer ${this.accessToken}`,
      "Content-Type": "application/json",
    };

    const response = await fetch(url.toString(), {
      method,
      headers,
      body: body ? JSON.stringify(body) : undefined,
    });

    if (!response.ok) {
      const errorText = await response.text();
      throw new Error(
        `Gmail API error: ${response.status} ${response.statusText} - ${errorText}`
      );
    }

    return await response.json();
  }

  public async getLabels(): Promise<GmailLabel[]> {
    const data = await this.call("/labels");
    return data.labels || [];
  }

  public async getThreads(
    labelId: string,
    pageToken?: string,
    maxResults: number = 20,
    query?: string
  ): Promise<{
    threads: Array<{ id: string; historyId: string }>;
    nextPageToken?: string;
    resultSizeEstimate: number;
  }> {
    const params: any = {
      labelIds: labelId,
      maxResults,
    };

    if (pageToken) {
      params.pageToken = pageToken;
    }

    if (query) {
      params.q = query;
    }

    const data = await this.call("/threads", { params });

    return {
      threads: data.threads || [],
      nextPageToken: data.nextPageToken,
      resultSizeEstimate: data.resultSizeEstimate || 0,
    };
  }

  public async getThread(threadId: string): Promise<GmailThread> {
    const data = await this.call(`/threads/${threadId}`, {
      params: { format: "full" },
    });
    return data as GmailThread;
  }

  public async setupWatch(
    labelId: string,
    topicName: string
  ): Promise<{
    historyId: string;
    expiration: string;
  }> {
    const data = await this.call("/watch", {
      method: "POST",
      body: {
        labelIds: [labelId],
        topicName,
      },
    });

    return {
      historyId: data.historyId,
      expiration: data.expiration,
    };
  }

  public async stopWatch(): Promise<void> {
    await this.call("/stop", { method: "POST" });
  }

  public async getHistory(
    startHistoryId: string,
    labelId?: string,
    pageToken?: string
  ): Promise<{
    history: Array<{
      id: string;
      messages?: GmailMessage[];
      messagesAdded?: Array<{ message: GmailMessage }>;
      messagesDeleted?: Array<{ message: { id: string } }>;
      labelsAdded?: Array<{ message: GmailMessage }>;
      labelsRemoved?: Array<{ message: { id: string } }>;
    }>;
    historyId: string;
    nextPageToken?: string;
  }> {
    const params: any = {
      startHistoryId,
      historyTypes: ["messageAdded", "messageDeleted"],
    };

    if (labelId) {
      params.labelId = labelId;
    }

    if (pageToken) {
      params.pageToken = pageToken;
    }

    const data = await this.call("/history", { params });

    return {
      history: data.history || [],
      historyId: data.historyId,
      nextPageToken: data.nextPageToken,
    };
  }
}

/**
 * Parses an email address header into name and email
 * Handles formats like "John Doe <john@example.com>" or "john@example.com"
 */
export function parseEmailAddress(headerValue: string): EmailAddress {
  const match = headerValue.match(/^(?:"?([^"]*)"?\s)?<?([^@]+@[^>]+)>?$/);

  if (match) {
    return {
      name: match[1]?.trim() || null,
      email: match[2].trim(),
    };
  }

  // Fallback: treat entire string as email
  return {
    name: null,
    email: headerValue.trim(),
  };
}


/**
 * Parses email addresses and returns NewActor[] for mentions.
 */
function parseEmailAddressesToNewActors(headerValue: string | null): NewActor[] {
  if (!headerValue) return [];

  return headerValue
    .split(",")
    .map((addr) => addr.trim())
    .filter((addr) => addr.length > 0)
    .map((addr) => {
      const parsed = parseEmailAddress(addr);
      return {
        email: parsed.email,
        name: parsed.name || undefined,
      } as NewActor;
    });
}

/**
 * Gets a specific header value from a message
 */
function getHeader(message: GmailMessage, name: string): string | null {
  const header = message.payload.headers.find(
    (h) => h.name.toLowerCase() === name.toLowerCase()
  );
  return header?.value || null;
}

/**
 * Extracts the body from a Gmail message (handles multipart messages)
 */
function extractBody(part: GmailMessagePart): string {
  // If this part has a body with data, return it
  if (part.body?.data) {
    // Gmail API returns base64url-encoded data
    const decoded = atob(part.body.data.replace(/-/g, "+").replace(/_/g, "/"));
    return decoded;
  }

  // If multipart, recursively search parts
  if (part.parts) {
    // Prefer plain text over HTML
    const textPart = part.parts.find((p) => p.mimeType === "text/plain");
    if (textPart) {
      return extractBody(textPart);
    }

    const htmlPart = part.parts.find((p) => p.mimeType === "text/html");
    if (htmlPart) {
      // For HTML, strip tags for plain text representation
      const html = extractBody(htmlPart);
      return stripHtmlTags(html);
    }

    // Try first part as fallback
    if (part.parts.length > 0) {
      return extractBody(part.parts[0]);
    }
  }

  return "";
}

/**
 * Strips HTML tags for plain text representation
 * This is a simple implementation - could be enhanced with a proper HTML parser
 */
function stripHtmlTags(html: string): string {
  return html
    .replace(/<style[^>]*>.*?<\/style>/gi, "")
    .replace(/<script[^>]*>.*?<\/script>/gi, "")
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

/**
 * Extracts attachment information from a Gmail message
 */
function extractAttachments(
  message: GmailMessage
): Array<{ filename: string; url: string }> {
  const attachments: Array<{ filename: string; url: string }> = [];

  function processPart(part: GmailMessagePart) {
    // Check if this part is an attachment
    if (part.filename && part.body?.attachmentId) {
      attachments.push({
        filename: part.filename,
        url: `https://mail.google.com/mail/u/0/#inbox/${message.id}`,
      });
    }

    // Recursively process sub-parts
    if (part.parts) {
      part.parts.forEach(processPart);
    }
  }

  processPart(message.payload);
  return attachments;
}

/**
 * Transforms a Gmail thread into a NewLinkWithNotes structure.
 * The subject becomes the link title, and each email becomes a Note.
 */
export function transformGmailThread(thread: GmailThread): NewLinkWithNotes {
  if (!thread.messages || thread.messages.length === 0) {
    // Return empty structure for invalid threads
    return {
      type: "email",
      title: "",
      notes: [],
    };
  }

  const parentMessage = thread.messages[0];
  const subject = getHeader(parentMessage, "Subject");

  // Canonical URL for the thread
  const canonicalUrl = `https://mail.google.com/mail/u/0/#inbox/${thread.id}`;

  // Extract preview from first message
  const firstMessageBody = extractBody(parentMessage.payload);
  const preview = firstMessageBody || parentMessage.snippet || null;

  // Create link
  const plotThread: NewLinkWithNotes = {
    source: canonicalUrl,
    type: "email",
    title: subject || "Email",
    created: new Date(parseInt(parentMessage.internalDate)),
    meta: {
      threadId: thread.id,
      historyId: thread.historyId,
    },
    sourceUrl: canonicalUrl,
    notes: [],
    preview,
  };

  // Create Notes for all messages (including first)
  for (const message of thread.messages) {
    const from = getHeader(message, "From");
    const to = getHeader(message, "To");
    const cc = getHeader(message, "Cc");

    const sender = from ? parseEmailAddress(from) : null;
    if (!sender) continue; // Skip messages without sender

    const body = extractBody(message.payload);

    // Combine to and cc for mentions - convert to NewActor[]
    const mentions: NewActor[] = [
      ...parseEmailAddressesToNewActors(to),
      ...parseEmailAddressesToNewActors(cc),
    ];

    // Create NewNote with idempotent key
    const note = {
      key: message.id,
      author: {
        email: sender.email,
        name: sender.name || undefined,
      } as NewActor,
      content: body || message.snippet,
      mentions: mentions.length > 0 ? mentions : undefined,
    };

    plotThread.notes!.push(note);
  }

  return plotThread;
}

/**
 * Syncs threads from a Gmail label/query with pagination
 * Returns threads and updated sync state
 */
export async function syncGmailChannel(
  api: GmailApi,
  state: SyncState,
  batchSize: number = 20
): Promise<{
  threads: GmailThread[];
  state: SyncState;
  hasMore: boolean;
}> {
  // Extract query from channelId if it's a search filter
  let labelId = state.channelId;
  let query: string | undefined;

  if (state.channelId.startsWith("search:")) {
    query = state.channelId.substring(7);
    labelId = "INBOX"; // Default to inbox for searches
  }

  const { threads: threadRefs, nextPageToken } = await api.getThreads(
    labelId,
    state.pageToken,
    batchSize,
    query
  );

  // Fetch full thread details
  const threads: GmailThread[] = [];
  for (const threadRef of threadRefs) {
    try {
      const thread = await api.getThread(threadRef.id);
      threads.push(thread);
    } catch (error) {
      console.error(`Failed to fetch thread ${threadRef.id}:`, error);
      // Continue with other threads even if one fails
    }
  }

  const newState: SyncState = {
    channelId: state.channelId,
    pageToken: nextPageToken,
    lastSyncTime: new Date(),
  };

  // Update historyId from the last thread if available
  if (threads.length > 0) {
    newState.historyId = threads[threads.length - 1].historyId;
  }

  return {
    threads,
    state: newState,
    hasMore: !!nextPageToken,
  };
}
