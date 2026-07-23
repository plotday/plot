import { ActionType } from "@plotday/twister/plot";
import type {
  NewLinkWithNotes,
  NewActor,
  NewContact,
  Action,
} from "@plotday/twister/plot";
import { markdownToPlainText } from "@plotday/twister/utils/markdown";
import { markdownToHtml } from "@plotday/twister/utils/markdown-html";
import { isNoReplySender } from "@plotday/email-classifier";


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
  /**
   * Oldest mail the backfill should fetch (the account's sync-history window).
   * Applied as a Gmail `after:` search bound so a label backfill stops at the
   * window edge instead of paginating the entire mailbox history — everything
   * older would be fetched, transformed, and then discarded on save anyway.
   * Unset on cursors persisted before this field existed; those finish their
   * walk unbounded. May round-trip storage as an ISO string, so consumers
   * re-wrap it in `new Date(...)`.
   */
  historyFloor?: Date;
};

/**
 * A non-OK response from Google's userinfo endpoint (used only to resolve the
 * account's display name for outbound `From` headers). Carries `status` so
 * callers can separate a misconfiguration — a 403 from the outbound proxy when
 * the endpoint is absent from the connector's Network allowlist, or from
 * Google when the grant lacks `profile` — from a transient failure.
 */
export class UserInfoError extends Error {
  constructor(
    public status: number,
    public statusText: string,
  ) {
    super(`UserInfo error: ${status} ${statusText}`);
    this.name = "UserInfoError";
  }
}

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

/**
 * True when a {@link GmailApiError} is a Gmail rate-limit / quota rejection:
 * an HTTP 429, or a 403 carrying one of Gmail's unambiguous quota markers
 * (`rateLimitExceeded` / `userRateLimitExceeded` / `Quota exceeded`). These are
 * expected under load and self-resolve once the per-user-per-minute window
 * clears, so callers retry/defer them rather than dropping the write-back or
 * paging error tracking. Gated on the markers — NOT a bare 403 — so genuine
 * permission failures (`Insufficient Permission`) still surface.
 */
export function isGmailRateLimitError(error: unknown): boolean {
  if (!(error instanceof GmailApiError)) return false;
  if (error.status === 429) return true;
  return (
    error.status === 403 &&
    /rateLimitExceeded|userRateLimitExceeded|Quota exceeded/i.test(error.message)
  );
}

/**
 * In-process retry budget for {@link GmailApi.call}. Kept small and short so a
 * brief blip (a momentary 429, a 5xx, a dropped connection) is absorbed inside
 * the current execution without risking the worker's wall-clock budget. Sustained
 * rate-limits exceed this and throw, so the caller (deferred write-back drain,
 * incremental-sync pending list) can reschedule past the quota window.
 */
const GMAIL_CALL_MAX_ATTEMPTS = 3;
const GMAIL_CALL_BACKOFF_MS = [500, 1500];
/**
 * Honor a server `Retry-After` only up to this bound; a longer wait belongs in a
 * scheduled retry, not an in-flight isolate, so we throw and let the caller defer.
 */
const GMAIL_RETRY_AFTER_MAX_MS = 3000;

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

    // Bounded in-process retry for transient failures (rate-limit / 5xx /
    // dropped connection). A momentary blip is absorbed here; a sustained one
    // exceeds the budget and throws so the caller can defer past the quota
    // window (see deferred write-back drain / incremental-sync pending list).
    let lastError: unknown;
    for (let attempt = 0; attempt < GMAIL_CALL_MAX_ATTEMPTS; attempt++) {
      let response: Response;
      try {
        response = await fetch(url.toString(), {
          method,
          headers,
          body: body ? JSON.stringify(body) : undefined,
        });
      } catch (networkError) {
        // fetch() rejects on a dropped/aborted connection — transient.
        lastError = networkError;
        if (attempt < GMAIL_CALL_MAX_ATTEMPTS - 1) {
          await this.sleep(GMAIL_CALL_BACKOFF_MS[attempt] ?? 0);
          continue;
        }
        throw networkError;
      }

      if (response.ok) {
        // Some Gmail endpoints — notably users.stop (POST /stop, used by
        // stopWatch) — return 204 No Content with an EMPTY body. Calling
        // response.json() on an empty body throws "SyntaxError: Unexpected end
        // of JSON input"; this escaped through setupWatch()'s unguarded
        // stopWatch() recovery path and surfaced as an unhandled twist
        // exception. Read the body as text and only parse it when non-empty.
        const text = await response.text();
        return text ? JSON.parse(text) : undefined;
      }

      const errorText = await response.text();
      const error = new GmailApiError(
        response.status,
        response.statusText,
        errorText
      );
      lastError = error;

      const retryable = isGmailRateLimitError(error) || response.status >= 500;
      if (!retryable || attempt >= GMAIL_CALL_MAX_ATTEMPTS - 1) {
        throw error;
      }

      const delayMs = this.retryDelayMs(response, attempt);
      // A long server-requested wait belongs in a scheduled retry, not here.
      if (delayMs === null) throw error;
      await this.sleep(delayMs);
    }

    // Unreachable in practice (the loop returns or throws), but satisfies the
    // type checker and surfaces any logic error rather than returning undefined.
    throw lastError instanceof Error
      ? lastError
      : new GmailApiError(0, "Retry loop exhausted", String(lastError));
  }

  private sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }

  /**
   * Backoff for a retryable response. Honors a `Retry-After` header (seconds or
   * HTTP date) up to {@link GMAIL_RETRY_AFTER_MAX_MS}; returns null when the
   * server asks for longer than that, signalling the caller to throw and defer
   * rather than block the isolate. Falls back to a fixed backoff schedule.
   */
  private retryDelayMs(response: Response, attempt: number): number | null {
    const retryAfter = response.headers.get("Retry-After");
    if (retryAfter) {
      const seconds = Number(retryAfter);
      let ms: number;
      if (Number.isFinite(seconds)) {
        ms = seconds * 1000;
      } else {
        const when = Date.parse(retryAfter);
        ms = Number.isNaN(when) ? NaN : when - Date.now();
      }
      if (Number.isFinite(ms)) {
        if (ms > GMAIL_RETRY_AFTER_MAX_MS) return null;
        return Math.max(0, ms);
      }
    }
    return (
      GMAIL_CALL_BACKOFF_MS[attempt] ??
      GMAIL_CALL_BACKOFF_MS[GMAIL_CALL_BACKOFF_MS.length - 1]
    );
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

  /**
   * Fetches a single message by id. Used to source a native forward (see
   * `buildForwardMessage`), where the caller has a message id — the note
   * `key` a Gmail-backed note carries — rather than a thread id.
   */
  public async getMessage(
    messageId: string,
    format: "full" | "minimal" | "metadata" | "raw" = "full"
  ): Promise<GmailMessage> {
    const data = await this.call(`/messages/${messageId}`, {
      params: { format },
    });
    return data as GmailMessage;
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
   * Fetches the authenticated user's profile via Google's userinfo endpoint
   * to get their display name — Gmail's own `/profile` only returns the
   * email address. Used to populate the `From` header with `"Name" <email>`
   * instead of a bare address (which Gmail displays without a name).
   */
  public async getUserInfo(): Promise<{ email: string; name?: string }> {
    const response = await fetch(
      "https://www.googleapis.com/oauth2/v3/userinfo",
      { headers: { Authorization: `Bearer ${this.accessToken}` } }
    );
    if (!response.ok) {
      throw new UserInfoError(response.status, response.statusText);
    }
    return response.json() as Promise<{ email: string; name?: string }>;
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
 * Canonicalizes a Gmail/Googlemail address for self-identity comparison.
 * Gmail treats dots in the local part and anything after a `+` as
 * insignificant for delivery — `kris.braun@gmail.com`, `krisbraun@gmail.com`,
 * and `kris.braun+tag@gmail.com` all route to the same mailbox — but message
 * headers preserve whichever exact variant was used to address the mail. A
 * literal string comparison against the account's canonical address (as
 * returned by the Gmail API) therefore misses these variants, letting the
 * user's own address survive into an outbound reply-all as if it were a
 * distinct recipient. Non-Gmail domains are returned lowercased, unchanged.
 */
export function canonicalizeGmailAddress(email: string): string {
  const lower = email.trim().toLowerCase();
  const at = lower.lastIndexOf("@");
  if (at === -1) return lower;
  const domain = lower.slice(at + 1);
  if (domain !== "gmail.com" && domain !== "googlemail.com") return lower;
  const local = lower.slice(0, at).split("+")[0]!.replace(/\./g, "");
  return `${local}@gmail.com`;
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

/** All values for a header name (case-insensitive), in message order. */
export function getHeaders(message: GmailMessage, name: string): string[] {
  const lower = name.toLowerCase();
  return (message.payload.headers ?? [])
    .filter((h) => h.name.toLowerCase() === lower)
    .map((h) => h.value);
}

/** Decoded HTML body for a message (empty string if none). For link extraction. */
export function getMessageHtml(message: GmailMessage): string {
  return findPartContent(message.payload, "text/html") ?? "";
}

/**
 * True when a mailing list (Google Groups, etc.) rewrote the `From` *address*
 * for DMARC alignment, so the From display name no longer belongs to the From
 * email address.
 *
 * A message from `Cloudflare <noreply@cloudflare.com>` distributed through the
 * `team@plot.day` group arrives as:
 *
 *     From: "Cloudflare via Plot Team" <team@plot.day>
 *     X-Original-Sender: noreply@cloudflare.com
 *
 * The display name ("Cloudflare") describes the original sender, but the From
 * email is now the *group* address. Naming the group contact after the From
 * display name overwrites the shared `contact.name` with each sender's name in
 * turn (server-side `normalizeName` even strips the " via <group>" suffix,
 * making the wrong name look clean). Callers should suppress the name on the
 * From-address contact when this returns true.
 *
 * Detection (in priority order):
 *  1. An `X-Original-Sender` / `X-Original-From` header whose address differs
 *     from the From address — the precise signal that the address was rewritten
 *     (and which leaves legit DMARC-passing list posts, where the original
 *     address is retained, untouched).
 *  2. Fallback when no original-sender header is present: the RFC 5322
 *     "<name> via <list>" display-name decoration, which only a list adds.
 */
export function isFromAddressRewritten(
  message: GmailMessage,
  fromEmail: string
): boolean {
  const originalHeader =
    getHeader(message, "X-Original-Sender") ??
    getHeader(message, "X-Original-From");
  if (originalHeader) {
    const originalEmail = parseEmailAddress(originalHeader.trim())?.email;
    if (originalEmail) {
      return originalEmail.toLowerCase() !== fromEmail.toLowerCase();
    }
  }
  const fromName = parseEmailAddress(getHeader(message, "From") ?? "")?.name;
  return !!fromName && /\svia\s/i.test(fromName);
}

/**
 * Extracts the body from a Gmail message (handles multipart messages).
 * Returns raw content with its type so HTML can be converted server-side.
 */
export function extractBody(part: GmailMessagePart): { content: string; contentType: "text" | "html" } {
  // Prefer HTML over plain text — server-side conversion produces cleaner output.
  // Search the WHOLE MIME tree, not just immediate children: forwarded messages
  // nest the real body inside a `message/rfc822` part (or a deeper multipart),
  // which the old immediate-children-only `find` missed, yielding an empty note.
  const html = findPartContent(part, "text/html");
  if (html) return { content: html, contentType: "html" };

  const text = findPartContent(part, "text/plain");
  if (text) return { content: text, contentType: "text" };

  return { content: "", contentType: "text" };
}

/**
 * Recursively finds the first non-empty body of the given MIME type in a Gmail
 * payload tree. Descends through multipart/* containers AND `message/rfc822`
 * parts (a forwarded email attached inline carries its original payload there).
 * Skips real attachments, whose bodies are binary and fetched separately.
 */
function findPartContent(part: GmailMessagePart, mimeType: string): string | null {
  const isAttachment = !!part.filename && !!part.body?.attachmentId;
  if (!isAttachment && part.mimeType === mimeType && part.body?.data) {
    return decodeBase64Url(part.body.data);
  }
  if (part.parts) {
    for (const child of part.parts) {
      const found = findPartContent(child, mimeType);
      if (found) return found;
    }
  }
  return null;
}

/** Decodes Gmail's base64url-encoded part data as UTF-8. */
function decodeBase64Url(data: string): string {
  const binaryString = atob(data.replace(/-/g, "+").replace(/_/g, "/"));
  const bytes = new Uint8Array(binaryString.length);
  for (let i = 0; i < binaryString.length; i++) {
    bytes[i] = binaryString.charCodeAt(i);
  }
  return new TextDecoder("utf-8").decode(bytes);
}

/** Unfold RFC 5545 lines (CRLF + leading space/tab is a continuation) and read a property. */
function icsProp(ics: string, name: string): string | null {
  const unfolded = ics.replace(/\r?\n[ \t]/g, "");
  const re = new RegExp(`^${name}(?:;[^:\\r\\n]*)?:(.*)$`, "im");
  const m = unfolded.match(re);
  return m ? m[1].trim() : null;
}

/**
 * Classify a Gmail conversation's relationship to a calendar event for bundling.
 * Two signals: our own `X-Plot-Event-UID` header (a Plot-sent reply chain), or a
 * `text/calendar` part (invitation/update/cancellation/RSVP). Only updates,
 * cancellations, and reply chains bundle; bare invites and RSVPs are skipped.
 */
export function classifyCalendarThread(
  messages: GmailMessage[]
): { uid: string; kind: "reply" | "update" | "cancel" } | null {
  // 1. Reply chain — our header on any message.
  for (const m of messages) {
    const uid = getHeader(m, "X-Plot-Event-UID");
    if (uid) return { uid, kind: "reply" };
  }
  // 2. Calendar-system ICS.
  for (const m of messages) {
    const ics = findPartContent(m.payload, "text/calendar");
    if (!ics) continue;
    const uid = icsProp(ics, "UID");
    if (!uid) continue;
    const method = (icsProp(ics, "METHOD") ?? "").toUpperCase();
    if (method === "CANCEL") return { uid, kind: "cancel" };
    if (method === "REQUEST") {
      const seq = parseInt(icsProp(ics, "SEQUENCE") ?? "0", 10);
      if (seq > 0) return { uid, kind: "update" };
    }
    // METHOD:REPLY, or REQUEST/SEQUENCE 0 → skip.
  }
  return null;
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
  // The date line is labelled "Sent:" by desktop Outlook / OWA but "Date:" by
  // Outlook for Mac / "new Outlook" — accept either.
  const re =
    /(?<=^|\n|[ \t]{3,})From:[\s\S]{0,1500}?(?<=\n|[ \t]{3,})(?:Sent|Date):[\s\S]{0,800}?(?<=\n|[ \t]{3,})To:[\s\S]{0,1500}?(?<=\n|[ \t]{3,})Subject:/i;
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

  // Forwarded messages: the forwarded email IS the content the user wants to
  // read. Gmail/Apple Mail wrap a forward in the same quote container Gmail uses
  // for reply quotes, so the reply-stripping below would delete the whole body
  // and leave an empty note. Keep the content as-is when it's a forward whose
  // marker precedes any reply boundary.
  if (isForwardedMessage(content)) return content;

  if (contentType === "html") {
    // Different mail clients wrap quoted history in different containers.
    // Collect every recognized quote boundary and cut at the EARLIEST one:
    // once the first boundary is reached, everything after it is quoted
    // history, even if it contains nested markers from a different client
    // (e.g. an Apple Mail reply whose quote embeds the Gmail original, which
    // still carries its own `gmail_quote` div deeper in the byte stream).
    const candidates: number[] = [];

    // Gmail wraps quoted replies in <div class="gmail_quote">.
    const gmailQuoteIdx = content.search(
      /<div[^>]*class\s*=\s*["'][^"']*gmail_quote[^"']*["'][^>]*>/i
    );
    if (gmailQuoteIdx !== -1) candidates.push(gmailQuoteIdx);

    // Some clients use <blockquote> with the gmail_quote class.
    const gmailBlockquoteIdx = content.search(
      /<blockquote[^>]*class\s*=\s*["'][^"']*gmail_quote[^"']*["'][^>]*>/i
    );
    if (gmailBlockquoteIdx !== -1) candidates.push(gmailBlockquoteIdx);

    // Apple Mail (Mail.app / iPhone Mail) wraps the "On <date>, <name>
    // wrote:" attribution and the quoted history in <blockquote type="cite">.
    const appleCiteIdx = content.search(
      /<blockquote[^>]*type\s*=\s*["']cite["'][^>]*>/i
    );
    if (appleCiteIdx !== -1) candidates.push(appleCiteIdx);

    // Yahoo Mail wraps quoted history in <div class="yahoo_quoted"> /
    // <div id="yahoo_quoted_...">.
    const yahooQuotedIdx = content.search(/<div[^>]*yahoo_quoted/i);
    if (yahooQuotedIdx !== -1) candidates.push(yahooQuotedIdx);

    // Microsoft Outlook-style: <div id="appendonsend"></div> or
    // <div id="divRplyFwdMsg"> before the quoted content.
    const outlookDivIdx = content.search(
      /<div[^>]*id\s*=\s*["'](?:appendonsend|divRplyFwdMsg)["'][^>]*>/i
    );
    if (outlookDivIdx !== -1) candidates.push(outlookDivIdx);

    // Outlook (desktop, OWA, and corporate Exchange clients) wraps replies
    // with a "From: / Sent: / To: / Subject:" header block. The markup
    // varies — sometimes `<b>` or `<strong>`, sometimes `<span
    // style="font-weight:bold">`, sometimes a `MsoNormal` paragraph with
    // no inline bold at all (Gowling-style corporate Exchange). The date line
    // is labelled "Sent:" by desktop Outlook / OWA but "Date:" by Outlook for
    // Mac / "new Outlook" (which also inserts a Cc: line between To: and
    // Subject:) — accept either label. Try the tight bold-wrapped pattern
    // first, then fall back to a tag-agnostic boundary match.
    const outlookHeaderRe =
      /<(b|strong)[^>]*>\s*From:?\s*<\/\1>[\s\S]{0,1000}<(b|strong)[^>]*>\s*(?:Sent|Date):?\s*<\/\2>[\s\S]{0,1500}<(b|strong)[^>]*>\s*To:?\s*<\/\3>[\s\S]{0,1500}<(b|strong)[^>]*>\s*Subject:?\s*<\/\4>/i;
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
      candidates.push(cut);
    }

    if (candidates.length > 0) {
      return content.substring(0, Math.min(...candidates)).trim();
    }

    return content;
  }

  // Plain text: look for "On ... wrote:" followed by quoted lines
  const lines = content.split("\n");
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();

    // "On [date], [name] wrote:" or "On [date], [name] <email> wrote:".
    // Some clients quote-prefix the attribution line itself (e.g. "> On ...
    // wrote:") instead of leaving it bare — allow an optional leading ">"
    // quote marker so that case is still recognized as the reply boundary.
    if (/^(?:>+\s*)*On .+ wrote:\s*$/.test(line)) {
      // Verify next non-empty line starts with ">" (actual quoted content)
      const nextContentLine = lines.slice(i + 1).find((l) => l.trim() !== "");
      if (nextContentLine && nextContentLine.trim().startsWith(">")) {
        return lines
          .slice(0, i)
          .join("\n")
          .trim();
      }
    }
  }

  return content;
}

/**
 * Detects a forwarded message so {@link stripQuotedReply} can preserve it.
 * Matches Gmail's dashed "---------- Forwarded message ---------" marker and
 * Apple Mail's "Begin forwarded message:". Returns false when a reply boundary
 * ("On … wrote:") precedes the forward marker — that's a reply quoting a
 * forward, which the reply-stripper should still trim.
 */
function isForwardedMessage(content: string): boolean {
  const fwdIdx = content.search(
    /(-{2,}\s*Forwarded message\s*-{2,}|Begin forwarded message:)/i
  );
  if (fwdIdx === -1) return false;
  const replyIdx = content.search(/On\s[\s\S]{0,200}?\swrote:/i);
  if (replyIdx !== -1 && replyIdx < fwdIdx) return false;
  return true;
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
    // Return empty structure for invalid threads. channelId is unknown at
    // this call site — the caller always sets the real value right after
    // (see "Inject channel ID" in sync.ts) before saving.
    return {
      channelId: null,
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
    // When a mailing list rewrote the From address (DMARC), its display name
    // describes the original sender, not the From (group) address — don't use
    // it to name the group's contact. See isFromAddressRewritten.
    const fromName =
      fromContact && !isFromAddressRewritten(message, fromContact.email)
        ? fromContact.name || undefined
        : undefined;
    const allParticipants: NewContact[] = [
      ...(fromContact
        ? [
            {
              email: fromContact.email,
              name: fromName,
              // See parseEmailAddressesToContacts for the email-vs-sub keying rationale.
              source: { accountId: fromContact.email.toLowerCase() },
              automated: isNoReplySender(fromContact.email),
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

  // Create link. channelId is unknown here — the caller always sets the
  // real value right after (see "Inject channel ID" in sync.ts) before saving.
  const plotThread: NewLinkWithNotes = {
    channelId: null,
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

    // Suppress the display name when the list rewrote the From address — it
    // belongs to the original sender, not this (group) address.
    const senderName = isFromAddressRewritten(message, sender.email)
      ? undefined
      : sender.name || undefined;
    const senderIsNoReply = isNoReplySender(sender.email);

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
      name: senderName,
      automated: senderIsNoReply,
    };
    const messageContacts: NewContact[] = [
      {
        email: sender.email,
        name: senderName,
        // See parseEmailAddressesToContacts for the email-vs-sub keying rationale.
        source: { accountId: sender.email.toLowerCase() },
        automated: senderIsNoReply,
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

  // Credit the thread to its originator — the first message's sender — so the
  // thread is authored by the human who started it, not the connection. We
  // reuse the first note's author so DMARC name suppression (above) carries
  // through. Without this the runtime defaults thread.author_id to the
  // connection's twist_instance (e.g. "Gmail (Plot)"), which then surfaces as
  // the author in notifications and the thread header.
  const originator = plotThread.notes![0]?.author;
  if (originator) plotThread.author = originator;

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
 * Concurrent `threads.get` fetches per pass. Serial fetching made the Gmail
 * round-trip (~hundreds of ms each) the pass's floor: 20 threads = 20 summed
 * round-trips. Five in flight keeps a 20-thread batch to ~4 round-trip spans
 * while staying far under Gmail's per-user quota (threads.get is 10 quota
 * units against a 250 units/sec budget).
 */
const THREAD_FETCH_CONCURRENCY = 5;

/**
 * Maps `items` with at most `limit` mappers in flight, resolving to results in
 * input order. A mapper rejection rejects the whole call — callers that want
 * per-item failure semantics catch inside `fn`.
 */
export async function mapWithConcurrency<T, R>(
  items: readonly T[],
  limit: number,
  fn: (item: T, index: number) => Promise<R>
): Promise<R[]> {
  const results = new Array<R>(items.length);
  let next = 0;
  const workers = Array.from(
    { length: Math.min(limit, items.length) },
    async () => {
      while (next < items.length) {
        const index = next++;
        results[index] = await fn(items[index], index);
      }
    }
  );
  await Promise.all(workers);
  return results;
}

/**
 * Builds the Gmail search bound for a backfill cursor: the channel's own query
 * (for `search:` pseudo-channels) combined with the sync-history floor as an
 * `after:` term (epoch seconds). Returns `undefined` when neither applies.
 */
function buildFullSyncQuery(
  channelQuery: string | undefined,
  historyFloor: Date | undefined
): string | undefined {
  const terms: string[] = [];
  if (channelQuery) terms.push(channelQuery);
  if (historyFloor) {
    const epochSeconds = Math.floor(new Date(historyFloor).getTime() / 1000);
    if (Number.isFinite(epochSeconds)) terms.push(`after:${epochSeconds}`);
  }
  return terms.length > 0 ? terms.join(" ") : undefined;
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
  let channelQuery: string | undefined;

  if (state.channelId.startsWith("search:")) {
    channelQuery = state.channelId.substring(7);
    labelId = "INBOX"; // Default to inbox for searches
  }

  const { threads: threadRefs, nextPageToken } = await api.getThreads(
    labelId,
    state.pageToken,
    batchSize,
    buildFullSyncQuery(channelQuery, state.historyFloor)
  );

  // Fetch full thread details, a bounded number in flight, in listing order.
  const threads = (
    await mapWithConcurrency(
      threadRefs,
      THREAD_FETCH_CONCURRENCY,
      async (threadRef): Promise<GmailThread | null> => {
        try {
          return await api.getThread(threadRef.id);
        } catch (error) {
          console.error(`Failed to fetch thread ${threadRef.id}:`, error);
          return null;
        }
      }
    )
  ).filter((thread): thread is GmailThread => thread !== null);

  const newState: SyncState = {
    channelId: state.channelId,
    pageToken: nextPageToken,
    lastSyncTime: new Date(),
    historyFloor: state.historyFloor,
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
 * Max history.list pages walked per incremental pass. Each page holds up to
 * ~100 history records; only thread IDs are retained, so the cap bounds API
 * calls per pass, not memory. When the cap is hit, the cursor advances to the
 * last record actually read (never past unread records) and the next pass
 * continues from there.
 */
export const MAX_HISTORY_PAGES_PER_PASS = 20;

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
 *
 * Thread fetches that fail (transient 5xx, rate limits, network) are NOT
 * silently dropped: their IDs are returned in `failedThreadIds`. The caller
 * advances the `historyId` cursor as usual (so we don't re-walk the whole
 * window) but must re-attempt the failed IDs on a subsequent sync by passing
 * them back via `retryThreadIds` — otherwise the cursor would move past
 * changes we never ingested, permanently losing that mail.
 */
export async function syncGmailMailboxIncremental(
  api: GmailApi,
  historyId: string,
  retryThreadIds: string[] = [],
  maxThreads: number = Infinity
): Promise<
  | { expired: true }
  | {
      expired: false;
      historyId: string;
      threads: GmailThread[];
      failedThreadIds: string[];
      /**
       * Thread ids that changed in this history window but were NOT fetched
       * this pass because the per-pass `maxThreads` budget was reached. The
       * caller carries these forward (see {@link mergePendingThreads}) and
       * schedules a continuation to drain them. Unbounded fetching here is what
       * let a large window (e.g. a cursor reseed after the Google re-home) load
       * thousands of full threads into one isolate and exceed the Worker memory
       * limit, which then tore down the in-flight DB connection mid-save
       * ("driver has already been destroyed").
       */
      deferredThreadIds: string[];
    }
> {
  // Walk the history window page by page, collecting changed thread ids
  // (small — ids only). history.list's top-level `historyId` is the CURRENT
  // mailbox history id regardless of pagination, so advancing the cursor to
  // it after reading only the first page would silently skip every change on
  // pages 2+ — losing mail under exactly the backlogged conditions that
  // produce multiple pages. If we stop before draining all pages (page cap),
  // we advance the cursor only to the id of the last history RECORD we read,
  // so the un-walked tail is picked up by the next pass.
  const changedThreadIds = new Set<string>(retryThreadIds);
  let pageToken: string | undefined;
  let pagesFetched = 0;
  let mailboxHistoryId: string | undefined;
  let lastReadRecordId: string | undefined;
  let truncated = false;
  do {
    let historyResult;
    try {
      historyResult = await api.getHistory(historyId, undefined, pageToken);
    } catch (error) {
      if (error instanceof GmailApiError && error.status === 404) {
        return { expired: true };
      }
      throw error;
    }
    mailboxHistoryId = historyResult.historyId;

    for (const entry of historyResult.history) {
      lastReadRecordId = entry.id;
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

    pageToken = historyResult.nextPageToken;
    pagesFetched++;
    if (pageToken && pagesFetched >= MAX_HISTORY_PAGES_PER_PASS) {
      truncated = true;
      break;
    }
  } while (pageToken);

  // Bound how many full threads we pull into memory per pass. `retryThreadIds`
  // are inserted into the Set first, so prior-deferred (and previously-failed)
  // threads sit at the front of iteration order and drain ahead of newly
  // changed ones. Everything past the cap is returned as `deferredThreadIds`.
  const ordered = [...changedThreadIds];
  const toFetch = ordered.slice(0, maxThreads);
  const deferredThreadIds = ordered.slice(toFetch.length);

  // Fetch a bounded number of threads in flight; results (and the failed
  // list) keep `toFetch` order — retry ids first — so downstream processing
  // is deterministic.
  const fetched = await mapWithConcurrency(
    toFetch,
    THREAD_FETCH_CONCURRENCY,
    async (threadId): Promise<GmailThread | null> => {
      try {
        return await api.getThread(threadId);
      } catch (error) {
        console.error(`Failed to fetch thread ${threadId}:`, error);
        return null;
      }
    }
  );
  const threads = fetched.filter(
    (thread): thread is GmailThread => thread !== null
  );
  const failedThreadIds = toFetch.filter((_, i) => fetched[i] === null);

  return {
    expired: false,
    historyId: truncated && lastReadRecordId ? lastReadRecordId : mailboxHistoryId!,
    threads,
    failedThreadIds,
    deferredThreadIds,
  };
}

/**
 * Strips CR, LF, and NUL from a value before it is interpolated into an
 * email header. Without this, an attacker-controlled subject or recipient
 * (e.g. `"Hi\r\nBcc: victim@example.com"`) would inject additional headers
 * into the outgoing message (RFC 5322 header injection). Header values must
 * be a single unfolded line; we collapse any control characters to a space.
 */
function sanitizeHeaderValue(value: string): string {
  return value.replace(/[\r\n\x00]+/g, " ").trim();
}

/**
 * Formats a `From` header value as `"Display Name" <email>` per RFC 5322,
 * falling back to a bare email address when no display name is available.
 * The name is quoted with internal quotes/backslashes escaped since Google
 * account names may contain commas or other special characters.
 */
export function formatFromHeader(email: string, name?: string | null): string {
  const cleanEmail = sanitizeHeaderValue(email);
  const cleanName = name ? sanitizeHeaderValue(name) : "";
  if (!cleanName) return cleanEmail;
  const escapedName = cleanName.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
  return `"${escapedName}" <${cleanEmail}>`;
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
  extraHeaders?: string[];
}): string {
  const { to, cc = [], bcc = [], from, subject, body } = options;

  // Sanitize every value interpolated into a header to prevent CRLF header
  // injection (RFC 5322) via attacker-controlled subjects or addresses.
  const toLine = to.map(sanitizeHeaderValue).join(", ");
  const ccLine = cc.map(sanitizeHeaderValue).join(", ");
  const bccLine = bcc.map(sanitizeHeaderValue).join(", ");

  const lines: string[] = [`From: ${sanitizeHeaderValue(from)}`];

  // Only emit recipient headers that have addresses. A message may be
  // addressed entirely via Cc/Bcc (no To). Gmail's send API delivers to
  // Bcc recipients and strips the Bcc header from the copy other
  // recipients receive, so listing them here does not expose them.
  if (to.length > 0) {
    lines.push(`To: ${toLine}`);
  }

  if (cc.length > 0) {
    lines.push(`Cc: ${ccLine}`);
  }

  if (bcc.length > 0) {
    lines.push(`Bcc: ${bccLine}`);
  }

  lines.push(`Subject: ${sanitizeHeaderValue(subject)}`);
  for (const h of options.extraHeaders ?? []) {
    lines.push(sanitizeHeaderValue(h));
  }
  lines.push(`MIME-Version: 1.0`);

  // Body is a multipart/alternative (plain text + rendered HTML) so recipients
  // get clean formatting instead of raw Markdown wrapped by their mail server.
  const altBoundary = mimeBoundary("alt");
  const rawMessage = [
    ...lines,
    ...buildAlternativeBlock(altBoundary, body),
  ].join("\r\n");

  return base64UrlEncodeMessage(rawMessage);
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

/** Generate a unique MIME multipart boundary with the given role suffix. */
function mimeBoundary(role: string): string {
  return `----=_PlotBoundary_${role}_${Date.now().toString(16)}`;
}

/** base64url-encode an RFC 2822 raw message for the Gmail send API. Chunked to
 * avoid `String.fromCharCode(...bytes)` stack overflow on large bodies. */
function base64UrlEncodeMessage(rawMessage: string): string {
  const msgBytes = new TextEncoder().encode(rawMessage);
  const CHUNK = 32768;
  let binary = "";
  for (let i = 0; i < msgBytes.length; i += CHUNK) {
    const slice = msgBytes.subarray(i, i + CHUNK);
    for (let j = 0; j < slice.length; j++) {
      binary += String.fromCharCode(slice[j]);
    }
  }
  return btoa(binary)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

/**
 * Build the lines of a `multipart/alternative` MIME entity (including its own
 * `Content-Type` header) carrying the note body as two parts: a clean
 * `text/plain` fallback (Markdown stripped to plain text, no hard column
 * wrapping) and a rendered `text/html` part.
 *
 * Sending both — instead of raw Markdown as a bare `text/plain` body — stops
 * the recipient's mail server from hard-wrapping prose mid-sentence and lets
 * formatting (bold, links, lists) render. Both parts are base64-encoded so the
 * declared `Content-Transfer-Encoding` matches the emitted bytes.
 *
 * The returned lines begin with the `Content-Type: multipart/alternative`
 * header, so the caller can place them directly after the message headers (as
 * the top-level body) or after a `multipart/mixed` boundary (nested alongside
 * attachments).
 */
function buildAlternativeBlock(altBoundary: string, body: string): string[] {
  const text = markdownToPlainText(body);
  const htmlFragment = markdownToHtml(body);
  const html = `<!DOCTYPE html>\r\n<html><body>\r\n${htmlFragment}\r\n</body></html>`;
  const enc = new TextEncoder();
  return [
    `Content-Type: multipart/alternative; boundary="${altBoundary}"`,
    "",
    `--${altBoundary}`,
    `Content-Type: text/plain; charset="UTF-8"`,
    `Content-Transfer-Encoding: base64`,
    "",
    uint8ArrayToBase64Lines(enc.encode(text)),
    `--${altBoundary}`,
    `Content-Type: text/html; charset="UTF-8"`,
    `Content-Transfer-Encoding: base64`,
    "",
    uint8ArrayToBase64Lines(enc.encode(html)),
    `--${altBoundary}--`,
  ];
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
  bcc?: string[];
  from: string;
  subject: string;
  body: string;
  messageId: string;
  references: string;
  attachments?: AttachmentData[];
  extraHeaders?: string[];
}): string {
  const { to, cc, bcc = [], from, subject, body, messageId, references, attachments } = options;

  // Sanitize every value interpolated into a header to prevent CRLF header
  // injection (RFC 5322) via attacker-controlled subjects or addresses.
  const fromHeader = sanitizeHeaderValue(from);
  const toHeader = to.map(sanitizeHeaderValue).join(", ");
  const ccHeader = cc.map(sanitizeHeaderValue).join(", ");
  const bccHeader = bcc.map(sanitizeHeaderValue).join(", ");
  const safeMessageId = sanitizeHeaderValue(messageId);
  const safeReferences = sanitizeHeaderValue(references);

  // Ensure subject has "Re:" prefix
  const reSubject = sanitizeHeaderValue(
    subject.startsWith("Re:") ? subject : `Re: ${subject}`
  );

  // Shared headers for both the attachment and no-attachment paths.
  const headerLines: string[] = [`From: ${fromHeader}`, `To: ${toHeader}`];
  if (cc.length > 0) headerLines.push(`Cc: ${ccHeader}`);
  // Gmail's messages.send honors a Bcc header and strips it from the delivered
  // copy, so bcc recipients stay hidden from To/Cc recipients.
  if (bcc.length > 0) headerLines.push(`Bcc: ${bccHeader}`);
  headerLines.push(`Subject: ${reSubject}`);
  headerLines.push(`In-Reply-To: ${safeMessageId}`);
  const refChain = safeReferences
    ? `${safeReferences} ${safeMessageId}`
    : safeMessageId;
  headerLines.push(`References: ${refChain}`);
  for (const h of options.extraHeaders ?? []) {
    headerLines.push(sanitizeHeaderValue(h));
  }
  headerLines.push(`MIME-Version: 1.0`);

  // The body is always a multipart/alternative (plain text + rendered HTML) so
  // recipients get clean formatting and MTAs don't hard-wrap raw Markdown.
  const altBoundary = mimeBoundary("alt");
  const altBlock = buildAlternativeBlock(altBoundary, body);

  let rawMessage: string;

  if (attachments && attachments.length > 0) {
    // Wrap the alternative body and the attachments in a multipart/mixed.
    const mixBoundary = mimeBoundary("mix");

    const attachmentParts: string[] = [];
    for (const att of attachments) {
      const b64Lines = uint8ArrayToBase64Lines(att.data);
      // Encode filename for Content-Disposition
      const safeFileName = att.fileName.replace(/[\r\n"]/g, "_");
      attachmentParts.push(
        `--${mixBoundary}`,
        `Content-Type: ${att.mimeType}; name="${safeFileName}"`,
        `Content-Transfer-Encoding: base64`,
        `Content-Disposition: attachment; filename="${safeFileName}"`,
        "",
        b64Lines,
      );
    }

    rawMessage = [
      ...headerLines,
      `Content-Type: multipart/mixed; boundary="${mixBoundary}"`,
      "", // end of message headers
      `--${mixBoundary}`,
      ...altBlock,
      ...attachmentParts,
      `--${mixBoundary}--`,
    ].join("\r\n");
  } else {
    // Top-level body is the multipart/alternative entity itself.
    rawMessage = [...headerLines, ...altBlock].join("\r\n");
  }

  return base64UrlEncodeMessage(rawMessage);
}

/**
 * Builds an RFC 2822 forward of an existing Gmail message. Gmail has no
 * native "forward" endpoint — a forward is just a new message sent via
 * `messages.send`. Unlike a reply, a forward starts a NEW thread (no
 * `In-Reply-To` / `References`). The body is the forwarder's own message
 * followed by a standard quoted-original attribution block; the original
 * message's attachments are re-attached.
 * Returns the base64url-encoded raw message string for the Gmail API.
 */
export function buildForwardMessage(options: {
  to: string[];
  cc: string[];
  /**
   * Optional — a forward's recipients come from the same role-tagged picker
   * as a compose, so a bcc-role recipient can appear here. Defaults to none.
   * Gmail's send API delivers to Bcc recipients and strips the Bcc header
   * from the copy other recipients receive (same as `buildNewEmailMessage`),
   * so listing them here does not expose them.
   */
  bcc?: string[];
  from: string;
  subject: string;
  body: string;
  originalHeader: string; // e.g. "From: … \n Date: … \n Subject: … \n To: …"
  originalBody: string; // the original message's text/markdown body
  attachments?: AttachmentData[];
}): string {
  const {
    to,
    cc,
    bcc = [],
    from,
    subject,
    body,
    originalHeader,
    originalBody,
    attachments,
  } = options;

  // Sanitize every value interpolated into a header to prevent CRLF header
  // injection (RFC 5322) via attacker-controlled subjects or addresses.
  const fromHeader = sanitizeHeaderValue(from);
  const toHeader = to.map(sanitizeHeaderValue).join(", ");
  const ccHeader = cc.map(sanitizeHeaderValue).join(", ");
  const bccHeader = bcc.map(sanitizeHeaderValue).join(", ");

  // Ensure subject has a "Fwd:" prefix, without doubling an existing one.
  const fwdSubject = sanitizeHeaderValue(
    subject.startsWith("Fwd:") ? subject : `Fwd: ${subject}`
  );

  // A forward starts a new thread, so — unlike buildReplyMessage — there is
  // no In-Reply-To / References header here.
  const headerLines: string[] = [`From: ${fromHeader}`, `To: ${toHeader}`];
  if (cc.length > 0) headerLines.push(`Cc: ${ccHeader}`);
  if (bcc.length > 0) headerLines.push(`Bcc: ${bccHeader}`);
  headerLines.push(`Subject: ${fwdSubject}`);
  headerLines.push(`MIME-Version: 1.0`);

  // Compose the visible body: the forwarder's own message (if any) on top of
  // a standard quoted-original attribution block.
  const quotedOriginal = [
    "---------- Forwarded message ----------",
    originalHeader,
    "",
    originalBody,
  ].join("\n");
  const composed = body.length > 0 ? `${body}\n\n${quotedOriginal}` : quotedOriginal;

  // The body is always a multipart/alternative (plain text + rendered HTML) so
  // recipients get clean formatting and MTAs don't hard-wrap raw Markdown.
  const altBoundary = mimeBoundary("alt");
  const altBlock = buildAlternativeBlock(altBoundary, composed);

  let rawMessage: string;

  if (attachments && attachments.length > 0) {
    // Wrap the alternative body and the re-attached attachments in a
    // multipart/mixed.
    const mixBoundary = mimeBoundary("mix");

    const attachmentParts: string[] = [];
    for (const att of attachments) {
      const b64Lines = uint8ArrayToBase64Lines(att.data);
      // Encode filename for Content-Disposition
      const safeFileName = att.fileName.replace(/[\r\n"]/g, "_");
      attachmentParts.push(
        `--${mixBoundary}`,
        `Content-Type: ${att.mimeType}; name="${safeFileName}"`,
        `Content-Transfer-Encoding: base64`,
        `Content-Disposition: attachment; filename="${safeFileName}"`,
        "",
        b64Lines,
      );
    }

    rawMessage = [
      ...headerLines,
      `Content-Type: multipart/mixed; boundary="${mixBoundary}"`,
      "", // end of message headers
      `--${mixBoundary}`,
      ...altBlock,
      ...attachmentParts,
      `--${mixBoundary}--`,
    ].join("\r\n");
  } else {
    // Top-level body is the multipart/alternative entity itself.
    rawMessage = [...headerLines, ...altBlock].join("\r\n");
  }

  return base64UrlEncodeMessage(rawMessage);
}
