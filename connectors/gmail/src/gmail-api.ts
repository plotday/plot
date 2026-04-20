import type {
  NewLinkWithNotes,
  NewActor,
  NewContact,
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

export class GmailApiError extends Error {
  constructor(
    public status: number,
    public statusText: string,
    body: string,
  ) {
    super(`Gmail API error: ${status} ${statusText} - ${body}`);
    this.name = "GmailApiError";
  }
}

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
        if (Array.isArray(value)) {
          for (const item of value) {
            url.searchParams.append(key, String(item));
          }
        } else {
          url.searchParams.append(key, String(value));
        }
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
      throw new GmailApiError(response.status, response.statusText, errorText);
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

  public async sendMessage(
    raw: string,
    threadId: string
  ): Promise<{ id: string; threadId: string }> {
    return await this.call("/messages/send", {
      method: "POST",
      body: { raw, threadId },
    });
  }

  public async getProfile(): Promise<{ emailAddress: string }> {
    return await this.call("/profile");
  }

  public async modifyThread(
    threadId: string,
    addLabelIds?: string[],
    removeLabelIds?: string[]
  ): Promise<void> {
    const body: Record<string, string[]> = {};
    if (addLabelIds?.length) body.addLabelIds = addLabelIds;
    if (removeLabelIds?.length) body.removeLabelIds = removeLabelIds;
    await this.call(`/threads/${threadId}/modify`, {
      method: "POST",
      body,
    });
  }

  /**
   * Checks if any message in a Gmail thread has the STARRED label.
   */
  static isStarred(thread: GmailThread): boolean {
    return thread.messages?.some(m => m.labelIds?.includes("STARRED")) ?? false;
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
      labelsRemoved?: Array<{ message: GmailMessage }>;
    }>;
    historyId: string;
    nextPageToken?: string;
  }> {
    const params: any = {
      startHistoryId,
      // Include label changes so starring (STARRED) or archiving (INBOX)
      // triggers a re-sync of the thread, not just new/deleted messages.
      historyTypes: ["messageAdded", "messageDeleted", "labelAdded", "labelRemoved"],
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
 * Parses an email address header into name and email.
 * Handles formats like "John Doe <john@example.com>" or "john@example.com".
 * Returns null for non-email values like "undisclosed-recipients:;".
 */
export function parseEmailAddress(headerValue: string): EmailAddress | null {
  const match = headerValue.match(/^(?:"?([^"]*)"?\s)?<?([^@\s]+@[^>\s]+)>?$/);
  if (!match) return null;
  return {
    name: match[1]?.trim() || null,
    email: match[2].trim(),
  };
}


/**
 * Splits a comma-separated email header into individual addresses, respecting
 * RFC 5322 quoted display names. `"Bayne, John" <john@x>, jane@y` must split
 * into two entries, not four — naive `split(",")` produces `"Bayne` as its own
 * chunk, which can leak into downstream contact storage as a garbage email.
 */
export function splitEmailList(headerValue: string): string[] {
  const parts: string[] = [];
  let current = "";
  let inQuotes = false;
  let escaped = false;
  for (const ch of headerValue) {
    if (escaped) {
      current += ch;
      escaped = false;
    } else if (ch === "\\") {
      current += ch;
      escaped = true;
    } else if (ch === '"') {
      inQuotes = !inQuotes;
      current += ch;
    } else if (ch === "," && !inQuotes) {
      if (current.trim()) parts.push(current);
      current = "";
    } else {
      current += ch;
    }
  }
  if (current.trim()) parts.push(current);
  return parts;
}

/**
 * Parses a comma-separated email header value into an array of email address strings.
 * Skips entries that are not valid email addresses (e.g. "undisclosed-recipients:;").
 */
export function parseEmailAddresses(headerValue: string | null): string[] {
  if (!headerValue) return [];
  return splitEmailList(headerValue)
    .map((addr) => parseEmailAddress(addr.trim())?.email)
    .filter((email): email is string => !!email);
}

/**
 * Parses email addresses from a header value into NewContact objects.
 * Used for thread/note accessContacts (visibility control).
 * Skips entries that are not valid email addresses.
 */
function parseEmailAddressesToContacts(headerValue: string | null): NewContact[] {
  if (!headerValue) return [];

  return splitEmailList(headerValue)
    .map((addr) => parseEmailAddress(addr.trim()))
    .filter((parsed): parsed is EmailAddress => parsed !== null)
    .map((parsed) => ({
      email: parsed.email,
      name: parsed.name || undefined,
    }));
}

/**
 * Gets a specific header value from a message
 */
export function getHeader(message: GmailMessage, name: string): string | null {
  const header = message.payload.headers.find(
    (h) => h.name.toLowerCase() === name.toLowerCase()
  );
  return header?.value || null;
}

/**
 * Extracts the body from a Gmail message (handles multipart messages).
 * Returns raw content with its type so HTML can be converted server-side.
 */
function extractBody(part: GmailMessagePart): { content: string; contentType: "text" | "html" } {
  // If this part has a body with data, return it
  if (part.body?.data) {
    // Gmail API returns base64url-encoded data — decode as UTF-8
    const binaryString = atob(part.body.data.replace(/-/g, "+").replace(/_/g, "/"));
    const bytes = new Uint8Array(binaryString.length);
    for (let i = 0; i < binaryString.length; i++) {
      bytes[i] = binaryString.charCodeAt(i);
    }
    const decoded = new TextDecoder("utf-8").decode(bytes);
    const contentType = part.mimeType === "text/html" ? "html" as const : "text" as const;
    return { content: decoded, contentType };
  }

  // If multipart, recursively search parts
  if (part.parts) {
    // Prefer HTML over plain text — server-side conversion produces cleaner output
    const htmlPart = part.parts.find((p) => p.mimeType === "text/html");
    if (htmlPart) {
      return extractBody(htmlPart);
    }

    const textPart = part.parts.find((p) => p.mimeType === "text/plain");
    if (textPart) {
      return extractBody(textPart);
    }

    // Try first part as fallback
    if (part.parts.length > 0) {
      return extractBody(part.parts[0]);
    }
  }

  return { content: "", contentType: "text" };
}

/**
 * Strips quoted reply content from an email body.
 * Since Plot shows each message as a separate note in a thread,
 * the quoted previous messages are redundant noise.
 */
function stripQuotedReply(
  content: string,
  contentType: "text" | "html"
): string {
  if (!content) return content;

  if (contentType === "html") {
    // Gmail wraps quoted replies in <div class="gmail_quote">
    // Remove it and everything after it
    const gmailQuoteIdx = content.search(
      /<div[^>]*class\s*=\s*["'][^"']*gmail_quote[^"']*["'][^>]*>/i
    );
    if (gmailQuoteIdx !== -1) {
      return content.substring(0, gmailQuoteIdx).trim();
    }

    // Some clients use <blockquote> with gmail_quote class
    const blockquoteIdx = content.search(
      /<blockquote[^>]*class\s*=\s*["'][^"']*gmail_quote[^"']*["'][^>]*>/i
    );
    if (blockquoteIdx !== -1) {
      return content.substring(0, blockquoteIdx).trim();
    }

    // Microsoft Outlook-style: <div id="appendonsend"></div> followed by quoted content,
    // or a <hr> divider followed by "From:" header pattern
    const outlookDivIdx = content.search(
      /<div[^>]*id\s*=\s*["'](?:appendonsend|divRplyFwdMsg)["'][^>]*>/i
    );
    if (outlookDivIdx !== -1) {
      return content.substring(0, outlookDivIdx).trim();
    }

    return content;
  }

  // Plain text: look for "On ... wrote:" followed by quoted lines
  const lines = content.split("\n");
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();

    // "On [date], [name] wrote:" or "On [date], [name] <email> wrote:"
    if (/^On .+ wrote:\s*$/.test(line)) {
      // Verify next non-empty line starts with ">" (actual quoted content)
      const nextContentLine = lines.slice(i + 1).find((l) => l.trim() !== "");
      if (nextContentLine && nextContentLine.trim().startsWith(">")) {
        return lines
          .slice(0, i)
          .join("\n")
          .trim();
      }
    }

    // Forwarded message separator
    if (line === "---------- Forwarded message ----------") {
      return lines
        .slice(0, i)
        .join("\n")
        .trim();
    }
  }

  return content;
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

  // Use Gmail's plain-text snippet for preview (avoids HTML in previews)
  const preview = parentMessage.snippet || null;

  // Collect all unique participants across messages for thread-level access
  const participantsByEmail = new Map<string, NewContact>();
  for (const message of thread.messages) {
    const from = getHeader(message, "From");
    const to = getHeader(message, "To");
    const cc = getHeader(message, "Cc");
    const fromContact = from ? parseEmailAddress(from) : null;
    const contacts: { email: string; name: string | null }[] = [
      ...(fromContact ? [fromContact] : []),
      ...parseEmailAddressesToContacts(to).map((c) => ({
        email: c.email!,
        name: c.name ?? null,
      })),
      ...parseEmailAddressesToContacts(cc).map((c) => ({
        email: c.email!,
        name: c.name ?? null,
      })),
    ];
    for (const actor of contacts) {
      const email = actor.email.toLowerCase();
      if (!participantsByEmail.has(email)) {
        participantsByEmail.set(email, {
          email: actor.email,
          name: actor.name || undefined,
        });
      }
    }
  }

  // Create link
  const plotThread: NewLinkWithNotes = {
    source: canonicalUrl,
    type: "email",
    title: subject || "Email",
    created: new Date(parseInt(parentMessage.internalDate)),
    access: "private",
    accessContacts: [...participantsByEmail.values()],
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

    const { content: rawBody, contentType } = extractBody(message.payload);
    const body = stripQuotedReply(rawBody, contentType);
    const attachments = extractAttachments(message);

    // Append attachment links to body
    let content = body || message.snippet;
    if (attachments.length > 0 && content) {
      const attachmentLinks = attachments
        .map((a) => `[${a.filename}](${a.url})`)
        .join("\n");
      content = content + "\n\n" + attachmentLinks;
    }

    // Note author (sender) and per-message recipients for visibility
    const senderActor: NewActor = {
      email: sender.email,
      name: sender.name || undefined,
    };
    const messageContacts: NewContact[] = [
      { email: sender.email, name: sender.name || undefined },
      ...parseEmailAddressesToContacts(to),
      ...parseEmailAddressesToContacts(cc),
    ];

    // Create NewNote with idempotent key
    const note = {
      key: message.id,
      author: senderActor,
      content,
      contentType,
      accessContacts: messageContacts,
      created: new Date(parseInt(message.internalDate)),
      checkForTasks: true,
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
  // Incremental sync: use History API to fetch only changed threads since last historyId.
  // This avoids re-listing all threads in the label on every webhook notification.
  if (state.historyId && !state.pageToken) {
    return syncGmailChannelIncremental(api, state, batchSize);
  }

  // Full sync (initial or paginated): list all threads in the label
  return syncGmailChannelFull(api, state, batchSize);
}

/**
 * Incremental sync using Gmail History API.
 * Fetches only threads that changed since the last historyId.
 */
async function syncGmailChannelIncremental(
  api: GmailApi,
  state: SyncState,
  batchSize: number
): Promise<{
  threads: GmailThread[];
  state: SyncState;
  hasMore: boolean;
}> {
  let labelId = state.channelId;
  if (state.channelId.startsWith("search:")) {
    labelId = "INBOX";
  }

  // Fetch history entries since last sync. Gmail returns 404 when the stored
  // historyId is outside the available history window (expired after ~7 days
  // of inactivity, or mailbox was reset). Per Gmail API docs, the client must
  // recover by performing a full sync.
  let historyResult;
  try {
    historyResult = await api.getHistory(state.historyId!, labelId);
  } catch (error) {
    if (error instanceof GmailApiError && error.status === 404) {
      console.warn(
        `Gmail history expired for channel ${state.channelId}; falling back to full sync`
      );
      return syncGmailChannelFull(
        api,
        { channelId: state.channelId, lastSyncTime: state.lastSyncTime },
        batchSize
      );
    }
    throw error;
  }

  // Extract unique thread IDs from history entries
  const changedThreadIds = new Set<string>();
  for (const entry of historyResult.history) {
    for (const added of entry.messagesAdded ?? []) {
      changedThreadIds.add(added.message.threadId);
    }
    for (const deleted of entry.messagesDeleted ?? []) {
      // Deleted messages only have id, not threadId — skip
    }
    // Label changes (STARRED add/remove, INBOX add/remove for archive, etc.)
    // carry the message's threadId so we can refetch the thread's current state.
    for (const labeled of entry.labelsAdded ?? []) {
      if (labeled.message.threadId) changedThreadIds.add(labeled.message.threadId);
    }
    for (const labeled of entry.labelsRemoved ?? []) {
      if (labeled.message.threadId) changedThreadIds.add(labeled.message.threadId);
    }
  }

  // Fetch full thread details for changed threads
  const threads: GmailThread[] = [];
  for (const threadId of changedThreadIds) {
    try {
      const thread = await api.getThread(threadId);
      threads.push(thread);
    } catch (error) {
      console.error(`Failed to fetch thread ${threadId}:`, error);
    }
  }

  return {
    threads,
    state: {
      channelId: state.channelId,
      historyId: historyResult.historyId,
      lastSyncTime: new Date(),
    },
    hasMore: false, // History API returns all changes in one call (with pagination handled internally)
  };
}

/**
 * Full sync: list all threads in the label, paginated.
 * Used for initial sync and when no historyId is available.
 */
async function syncGmailChannelFull(
  api: GmailApi,
  state: SyncState,
  batchSize: number
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

/**
 * Builds an RFC 2822 email message for replying to a Gmail thread.
 * Returns the base64url-encoded raw message string for the Gmail API.
 */
export function buildReplyMessage(options: {
  to: string[];
  cc: string[];
  from: string;
  subject: string;
  body: string;
  messageId: string;
  references: string;
}): string {
  const { to, cc, from, subject, body, messageId, references } = options;

  // Ensure subject has "Re:" prefix
  const reSubject = subject.startsWith("Re:") ? subject : `Re: ${subject}`;

  // Build RFC 2822 headers
  const lines: string[] = [
    `From: ${from}`,
    `To: ${to.join(", ")}`,
  ];

  if (cc.length > 0) {
    lines.push(`Cc: ${cc.join(", ")}`);
  }

  lines.push(`Subject: ${reSubject}`);
  lines.push(`In-Reply-To: ${messageId}`);

  // Build References chain
  const refChain = references
    ? `${references} ${messageId}`
    : messageId;
  lines.push(`References: ${refChain}`);

  lines.push(`Content-Type: text/plain; charset="UTF-8"`);
  lines.push(""); // Empty line separates headers from body
  lines.push(body);

  const rawMessage = lines.join("\r\n");

  // Base64url encode
  const encoded = btoa(
    String.fromCharCode(...new TextEncoder().encode(rawMessage))
  )
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");

  return encoded;
}
