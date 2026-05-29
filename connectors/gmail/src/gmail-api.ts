import { ActionType } from "@plotday/twister/plot";
import type {
  NewLinkWithNotes,
  NewActor,
  NewContact,
  Action,
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
    topicName: string,
    labelId?: string
  ): Promise<{
    historyId: string;
    expiration: string;
  }> {
    const body: { topicName: string; labelIds?: string[] } = { topicName };
    // Mailbox-wide watch when no labelId is provided. Gmail enforces one
    // push-notification client per (mailbox, OAuth project); a watch() with a
    // DIFFERENT topicName while a prior watch is active returns 400 with
    // "Only one user push notification client allowed per developer (call
    // /stop then try again)". A watch() with the SAME topicName is a no-op
    // that renews the expiration.
    if (labelId) {
      body.labelIds = [labelId];
    }
    let data: any;
    try {
      data = await this.call("/watch", { method: "POST", body });
    } catch (error) {
      // Honor Gmail's recovery hint: if a stale watch is blocking us, stop
      // it and retry once. Hit when setupMailboxWebhook's best-effort
      // stopWatch() failed (network blip, transient 5xx) and the next
      // setupWatch is using a fresh topic name.
      if (
        error instanceof GmailApiError &&
        error.status === 400 &&
        error.message.includes("Only one user push notification client allowed")
      ) {
        await this.stopWatch();
        data = await this.call("/watch", { method: "POST", body });
      } else {
        throw error;
      }
    }

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

  /**
   * Sends a brand-new email (not a reply). Gmail allocates a fresh threadId.
   */
  public async sendNewMessage(
    raw: string
  ): Promise<{ id: string; threadId: string }> {
    return await this.call("/messages/send", {
      method: "POST",
      body: { raw },
    });
  }

  public async getProfile(): Promise<{ emailAddress: string }> {
    return await this.call("/profile");
  }

  /**
   * Fetches a message attachment by its attachment ID.
   * Returns the base64url-encoded attachment data.
   */
  public async getAttachment(
    messageId: string,
    attachmentId: string
  ): Promise<{ data: string; size: number }> {
    return await this.call(`/messages/${messageId}/attachments/${attachmentId}`);
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
 *
 * Always populates `source` with the email as the Google account ID so
 * the DM recipient picker can resolve contacts to Gmail email addresses
 * without requiring the Google Contacts connector to be installed.
 */
function parseEmailAddressesToContacts(headerValue: string | null): NewContact[] {
  if (!headerValue) return [];

  return splitEmailList(headerValue)
    .map((addr) => parseEmailAddress(addr.trim()))
    .filter((parsed): parsed is EmailAddress => parsed !== null)
    .map((parsed) => ({
      email: parsed.email,
      name: parsed.name || undefined,
      // NOTE: Gmail message headers don't expose a Google user id (sub/permissionId),
      // so we key contact_external_account on the lowercased email address. Google Chat
      // and Drive connectors key on the numeric Google id; cross-connector dedup is
      // also blocked by per-connection scoping, so the picker only surfaces a Gmail
      // contact for Gmail composes regardless. Acceptable for v1.
      source: { accountId: parsed.email.toLowerCase() },
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
 * Locates the start of an Outlook-style "From: / Sent: / To: / Subject:"
 * reply header even when the field labels are not wrapped in `<b>` or
 * `<strong>` — e.g. corporate Exchange / Outlook variants that put the
 * label in a `<span style="font-weight:bold">`, a `<font>` tag, or a
 * plain `MsoNormal` paragraph with no inline bold at all.
 *
 * Strategy: replace every HTML tag with a same-length run of spaces so
 * character offsets in the stripped text still map 1:1 back to the
 * original. Then require each label to start at a structural boundary
 * (start of string, a real newline, or 3+ whitespace chars — the smallest
 * gap any HTML block tag produces when replaced). That anchor is what
 * keeps user-written prose from false-matching.
 *
 * Returns the index of "From:" in the original content, or -1 if no
 * Outlook reply header is found.
 */
export function findOutlookHeaderTagAgnostic(content: string): number {
  const flat = content.replace(/<[^>]*>/g, (m) => " ".repeat(m.length));
  const re =
    /(?<=^|\n|[ \t]{3,})From:[\s\S]{0,1500}?(?<=\n|[ \t]{3,})Sent:[\s\S]{0,800}?(?<=\n|[ \t]{3,})To:[\s\S]{0,1500}?(?<=\n|[ \t]{3,})Subject:/i;
  const m = flat.match(re);
  return m?.index ?? -1;
}

/**
 * Strips quoted reply content from an email body.
 * Since Plot shows each message as a separate note in a thread,
 * the quoted previous messages are redundant noise.
 */
export function stripQuotedReply(
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

    // Outlook (desktop, OWA, and corporate Exchange clients) wraps replies
    // with a "From: / Sent: / To: / Subject:" header block. The markup
    // varies — sometimes `<b>` or `<strong>`, sometimes `<span
    // style="font-weight:bold">`, sometimes a `MsoNormal` paragraph with
    // no inline bold at all (Gowling-style corporate Exchange). Try the
    // tight bold-wrapped pattern first, then fall back to a tag-agnostic
    // boundary match.
    const outlookHeaderRe =
      /<(b|strong)[^>]*>\s*From:?\s*<\/\1>[\s\S]{0,1000}<(b|strong)[^>]*>\s*Sent:?\s*<\/\2>[\s\S]{0,1000}<(b|strong)[^>]*>\s*To:?\s*<\/\3>[\s\S]{0,1000}<(b|strong)[^>]*>\s*Subject:?\s*<\/\4>/i;
    const outlookHeaderMatch = content.match(outlookHeaderRe);
    const fromIdx =
      outlookHeaderMatch?.index ?? findOutlookHeaderTagAgnostic(content);
    if (fromIdx !== -1) {
      const lookbackStart = Math.max(0, fromIdx - 1000);
      const lookback = content.substring(lookbackStart, fromIdx);
      // Prefer the latest structural divider (border-top div or <hr>)
      // before the From: tag — that's the user/quoted boundary in
      // Outlook's standard reply format.
      const dividerRe =
        /<hr\b[^>]*>|<div[^>]*style\s*=\s*["'][^"']*border-top\s*:[^"']*["'][^>]*>/gi;
      let lastDivider = -1;
      let match: RegExpExecArray | null;
      while ((match = dividerRe.exec(lookback)) !== null) {
        lastDivider = match.index;
      }
      let cut = fromIdx;
      if (lastDivider !== -1) {
        cut = lookbackStart + lastDivider;
      } else {
        // No divider — cut at the start of the wrapping <p> or <div>.
        const lastP = lookback.lastIndexOf("<p");
        const lastDiv = lookback.lastIndexOf("<div");
        const wrapper = Math.max(lastP, lastDiv);
        if (wrapper !== -1) {
          cut = lookbackStart + wrapper;
        }
      }
      return content.substring(0, cut).trim();
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
 * Recursively collects attachment parts from a Gmail message payload.
 * An attachment part has a non-empty filename and a body.attachmentId.
 */
export function collectAttachments(
  part: GmailMessagePart | undefined
): Array<{
  partId: string;
  fileName: string;
  fileSize: number | null;
  mimeType: string;
}> {
  if (!part) return [];
  const here =
    part.filename && part.body?.attachmentId
      ? [
          {
            partId: part.body.attachmentId,
            fileName: part.filename,
            fileSize: part.body?.size ?? null,
            mimeType: part.mimeType ?? "application/octet-stream",
          },
        ]
      : [];
  const children = (part.parts ?? []).flatMap(collectAttachments);
  return [...here, ...children];
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

  // Collect all unique participants across messages for thread-level access.
  // source is populated so the DM recipient picker can resolve Gmail contacts.
  const participantsByEmail = new Map<string, NewContact>();
  for (const message of thread.messages) {
    const from = getHeader(message, "From");
    const to = getHeader(message, "To");
    const cc = getHeader(message, "Cc");
    const fromContact = from ? parseEmailAddress(from) : null;
    const allParticipants: NewContact[] = [
      ...(fromContact
        ? [
            {
              email: fromContact.email,
              name: fromContact.name || undefined,
              // See parseEmailAddressesToContacts for the email-vs-sub keying rationale.
              source: { accountId: fromContact.email.toLowerCase() },
            } as NewContact,
          ]
        : []),
      ...parseEmailAddressesToContacts(to),
      ...parseEmailAddressesToContacts(cc),
    ];
    for (const contact of allParticipants) {
      const email = contact.email!.toLowerCase();
      if (!participantsByEmail.has(email)) {
        participantsByEmail.set(email, contact);
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

  // Create Notes for all messages (including first). Skip drafts: Gmail
  // autosave replaces the draft message id on every keystroke, so without
  // this filter each autosave creates a fresh note keyed on the new id.
  for (const message of thread.messages) {
    if (message.labelIds?.includes("DRAFT")) continue;
    const from = getHeader(message, "From");
    const to = getHeader(message, "To");
    const cc = getHeader(message, "Cc");

    const sender = from ? parseEmailAddress(from) : null;
    if (!sender) continue; // Skip messages without sender

    const { content: rawBody, contentType } = extractBody(message.payload);
    const body = stripQuotedReply(rawBody, contentType);
    const attachmentParts = collectAttachments(message.payload);

    const content = body || message.snippet;

    // Build fileRef actions for each attachment part
    const actions: Action[] = attachmentParts.map((a) => ({
      type: ActionType.fileRef as ActionType.fileRef,
      ref: `${message.id}:${a.partId}`,
      fileName: a.fileName,
      fileSize: a.fileSize,
      mimeType: a.mimeType,
    }));

    // Note author (sender) and per-message recipients for visibility.
    // source is populated so the DM recipient picker can resolve Gmail contacts.
    const senderActor: NewActor = {
      email: sender.email,
      name: sender.name || undefined,
    };
    const messageContacts: NewContact[] = [
      {
        email: sender.email,
        name: sender.name || undefined,
        // See parseEmailAddressesToContacts for the email-vs-sub keying rationale.
        source: { accountId: sender.email.toLowerCase() },
      },
      ...parseEmailAddressesToContacts(to),
      ...parseEmailAddressesToContacts(cc),
    ];

    // Create NewNote with idempotent key
    const note = {
      key: message.id,
      author: senderActor,
      content,
      contentType,
      actions: actions.length > 0 ? actions : null,
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
 * Mailbox-wide incremental sync. Calls the Gmail History API without a
 * `labelId` filter, so it returns every change in the mailbox since
 * `historyId` — including replies in existing threads that don't carry the
 * label of any enabled channel. The connector decides per-thread whether
 * the change is relevant to any enabled channel.
 *
 * Returns the new `historyId` to persist, and the deduped set of changed
 * thread IDs (with their fetched full thread payloads). On 404 (history
 * window expired), returns `expired: true` so the caller can fall back to
 * a per-channel full re-sync.
 */
export async function syncGmailMailboxIncremental(
  api: GmailApi,
  historyId: string
): Promise<
  | { expired: true }
  | { expired: false; historyId: string; threads: GmailThread[] }
> {
  let historyResult;
  try {
    historyResult = await api.getHistory(historyId);
  } catch (error) {
    if (error instanceof GmailApiError && error.status === 404) {
      return { expired: true };
    }
    throw error;
  }

  const changedThreadIds = new Set<string>();
  for (const entry of historyResult.history) {
    for (const added of entry.messagesAdded ?? []) {
      changedThreadIds.add(added.message.threadId);
    }
    for (const labeled of entry.labelsAdded ?? []) {
      if (labeled.message.threadId)
        changedThreadIds.add(labeled.message.threadId);
    }
    for (const labeled of entry.labelsRemoved ?? []) {
      if (labeled.message.threadId)
        changedThreadIds.add(labeled.message.threadId);
    }
  }

  const threads: GmailThread[] = [];
  for (const threadId of changedThreadIds) {
    try {
      threads.push(await api.getThread(threadId));
    } catch (error) {
      console.error(`Failed to fetch thread ${threadId}:`, error);
    }
  }

  return {
    expired: false,
    historyId: historyResult.historyId,
    threads,
  };
}

/**
 * Builds an RFC 2822 email message for a new (non-reply) email.
 * Returns the base64url-encoded raw message string for the Gmail API.
 */
export function buildNewEmailMessage(options: {
  to: string[];
  cc?: string[];
  bcc?: string[];
  from: string;
  subject: string;
  body: string;
}): string {
  const { to, cc = [], bcc = [], from, subject, body } = options;

  const lines: string[] = [`From: ${from}`];

  // Only emit recipient headers that have addresses. A message may be
  // addressed entirely via Cc/Bcc (no To). Gmail's send API delivers to
  // Bcc recipients and strips the Bcc header from the copy other
  // recipients receive, so listing them here does not expose them.
  if (to.length > 0) {
    lines.push(`To: ${to.join(", ")}`);
  }

  if (cc.length > 0) {
    lines.push(`Cc: ${cc.join(", ")}`);
  }

  if (bcc.length > 0) {
    lines.push(`Bcc: ${bcc.join(", ")}`);
  }

  lines.push(`Subject: ${subject}`);
  lines.push(`Content-Type: text/plain; charset="UTF-8"`);
  lines.push(""); // Empty line separates headers from body
  lines.push(body);

  const rawMessage = lines.join("\r\n");

  // Base64url encode
  return btoa(
    String.fromCharCode(...new TextEncoder().encode(rawMessage))
  )
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

/**
 * Encodes a Uint8Array to a standard base64 string in 76-character lines
 * (MIME line length limit). Uses chunked processing to avoid stack overflow
 * on large files (avoids String.fromCharCode(...buffer) spread).
 */
function uint8ArrayToBase64Lines(bytes: Uint8Array): string {
  const CHUNK = 32768;
  let binary = "";
  for (let i = 0; i < bytes.length; i += CHUNK) {
    const slice = bytes.subarray(i, i + CHUNK);
    for (let j = 0; j < slice.length; j++) {
      binary += String.fromCharCode(slice[j]);
    }
  }
  const b64 = btoa(binary);
  // Split into 76-character MIME lines
  const lines: string[] = [];
  for (let i = 0; i < b64.length; i += 76) {
    lines.push(b64.slice(i, i + 76));
  }
  return lines.join("\r\n");
}

/**
 * Attachment data for building MIME messages.
 */
export type AttachmentData = {
  fileName: string;
  mimeType: string;
  data: Uint8Array;
};

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
  attachments?: AttachmentData[];
}): string {
  const { to, cc, from, subject, body, messageId, references, attachments } = options;

  // Ensure subject has "Re:" prefix
  const reSubject = subject.startsWith("Re:") ? subject : `Re: ${subject}`;

  let rawMessage: string;

  if (attachments && attachments.length > 0) {
    // Build multipart/mixed message with text body + attachment parts
    const boundary = `----=_PlotBoundary_${Date.now().toString(16)}`;

    const headerLines: string[] = [
      `From: ${from}`,
      `To: ${to.join(", ")}`,
    ];
    if (cc.length > 0) headerLines.push(`Cc: ${cc.join(", ")}`);
    headerLines.push(`Subject: ${reSubject}`);
    headerLines.push(`In-Reply-To: ${messageId}`);
    const refChain = references ? `${references} ${messageId}` : messageId;
    headerLines.push(`References: ${refChain}`);
    headerLines.push(`MIME-Version: 1.0`);
    headerLines.push(`Content-Type: multipart/mixed; boundary="${boundary}"`);
    headerLines.push(""); // end of headers

    // Text body part
    const bodyPart = [
      `--${boundary}`,
      `Content-Type: text/plain; charset="UTF-8"`,
      `Content-Transfer-Encoding: quoted-printable`,
      "",
      body,
    ];

    // Attachment parts
    const attachmentParts: string[] = [];
    for (const att of attachments) {
      const b64Lines = uint8ArrayToBase64Lines(att.data);
      // Encode filename for Content-Disposition
      const safeFileName = att.fileName.replace(/[\r\n"]/g, "_");
      attachmentParts.push(
        `--${boundary}`,
        `Content-Type: ${att.mimeType}; name="${safeFileName}"`,
        `Content-Transfer-Encoding: base64`,
        `Content-Disposition: attachment; filename="${safeFileName}"`,
        "",
        b64Lines,
      );
    }

    rawMessage = [
      headerLines.join("\r\n"),
      bodyPart.join("\r\n"),
      ...attachmentParts.map((p) => p),
      `--${boundary}--`,
    ].join("\r\n");
  } else {
    // Simple text-only message (existing path)
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

    rawMessage = lines.join("\r\n");
  }

  // Base64url encode the entire raw message
  const msgBytes = new TextEncoder().encode(rawMessage);
  const CHUNK = 32768;
  let binary = "";
  for (let i = 0; i < msgBytes.length; i += CHUNK) {
    const slice = msgBytes.subarray(i, i + CHUNK);
    for (let j = 0; j < slice.length; j++) {
      binary += String.fromCharCode(slice[j]);
    }
  }
  const encoded = btoa(binary)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");

  return encoded;
}
