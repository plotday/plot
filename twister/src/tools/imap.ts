import { ITool } from "..";

/** Opaque session handle returned by connect(). */
export type ImapSession = string;

/** Credentials and server info for connecting to an IMAP server. */
export type ImapConnectOptions = {
  /** IMAP server hostname (e.g. "imap.mail.me.com") */
  host: string;
  /** IMAP server port (e.g. 993 for TLS) */
  port: number;
  /** Whether to use TLS (true for port 993) */
  tls: boolean;
  /** IMAP username (typically the email address) */
  username: string;
  /** IMAP password (app-specific password for Apple) */
  password: string;
};

/** A mailbox returned by listMailboxes(). */
export type ImapMailbox = {
  /** Mailbox name (e.g. "INBOX", "Sent Messages") */
  name: string;
  /** Hierarchy delimiter (e.g. "/") */
  delimiter: string;
  /** Mailbox flags (e.g. ["\\HasNoChildren"]) */
  flags: string[];
  /** Special-use attribute if present (e.g. "\\Sent", "\\Drafts", "\\Trash") */
  specialUse?: string;
};

/** Status of a selected mailbox. */
export type ImapMailboxStatus = {
  /** Mailbox name */
  name: string;
  /** Total number of messages */
  exists: number;
  /** Number of recent messages */
  recent: number;
  /** UID validity value (changes if UIDs are reassigned) */
  uidValidity: number;
  /** Next UID to be assigned */
  uidNext: number;
  /** Number of unseen messages (may be absent) */
  unseen?: number;
};

/** Criteria for searching messages. All fields are optional; they are ANDed together. */
export type ImapSearchCriteria = {
  /** Messages with internal date on or after this date */
  since?: Date | string;
  /** Messages with internal date before this date */
  before?: Date | string;
  /** Messages with From header containing this string */
  from?: string;
  /** Messages with To header containing this string */
  to?: string;
  /** Messages with Subject containing this string */
  subject?: string;
  /** If true, only unseen messages; if false, only seen messages */
  unseen?: boolean;
  /** If true, only flagged messages; if false, only unflagged messages */
  flagged?: boolean;
  /** Specific UIDs to match */
  uid?: number[];
};

/** An email address with optional display name. */
export type ImapAddress = {
  /** Display name (e.g. "John Doe") */
  name?: string;
  /** Email address (e.g. "john@example.com") */
  address: string;
};

/** A fetched message. Fields are populated based on ImapFetchOptions. */
export type ImapMessage = {
  /** Message UID (stable across sessions if uidValidity hasn't changed) */
  uid: number;
  /** Message flags (e.g. ["\\Seen", "\\Flagged"]) */
  flags: string[];
  /** Internal date of the message */
  date?: Date;
  /** Subject header */
  subject?: string;
  /** From addresses */
  from?: ImapAddress[];
  /** To addresses */
  to?: ImapAddress[];
  /** CC addresses */
  cc?: ImapAddress[];
  /** Message-ID header */
  messageId?: string;
  /** In-Reply-To header (for threading) */
  inReplyTo?: string;
  /** References header (for threading) */
  references?: string[];
  /** Plain text body (when requested) */
  bodyText?: string;
  /** HTML body (when requested) */
  bodyHtml?: string;
  /** Message size in bytes */
  size?: number;
};

/** Options for fetchMessages(). */
export type ImapFetchOptions = {
  /** Fetch envelope/headers. Default: true. */
  headers?: boolean;
  /** Fetch body content. Default: false. */
  body?: boolean;
  /** Which body parts to fetch when body is true. Default: "both". */
  bodyType?: "text" | "html" | "both";
};

/** How to modify flags. */
export type ImapFlagOperation = "add" | "remove" | "set";

/**
 * Built-in tool for IMAP email access.
 *
 * Provides high-level IMAP operations for reading email and managing flags.
 * Handles TCP/TLS connections, IMAP protocol details, and MIME decoding
 * internally.
 *
 * **Permission model:** Connectors declare which IMAP hosts they need access
 * to. Connections to undeclared hosts are rejected.
 *
 * @example
 * ```typescript
 * class AppleMailConnector extends Connector<AppleMailConnector> {
 *   build(build: ConnectorBuilder) {
 *     return {
 *       options: build(Options, {
 *         email: { type: "text", label: "Apple ID Email", default: "" },
 *         password: { type: "text", label: "App-Specific Password", secure: true, default: "" },
 *       }),
 *
 *       imap: build(Imap, { hosts: ["imap.mail.me.com"] }),
 *       integrations: build(Integrations),
 *     };
 *   }
 *
 *   async syncInbox() {
 *     const session = await this.tools.imap.connect({
 *       host: "imap.mail.me.com",
 *       port: 993,
 *       tls: true,
 *       username: this.tools.options.email,
 *       password: this.tools.options.password,
 *     });
 *
 *     try {
 *       await this.tools.imap.selectMailbox(session, "INBOX");
 *       const uids = await this.tools.imap.search(session, { unseen: true });
 *       const messages = await this.tools.imap.fetchMessages(session, uids, {
 *         body: true,
 *         bodyType: "html",
 *       });
 *
 *       for (const msg of messages) {
 *         await this.tools.integrations.saveLink({
 *           source: `apple-mail:${msg.messageId}`,
 *           title: msg.subject ?? "(no subject)",
 *           // ...
 *         });
 *       }
 *     } finally {
 *       await this.tools.imap.disconnect(session);
 *     }
 *   }
 * }
 * ```
 */
export abstract class Imap extends ITool {
  static readonly Options: {
    /** IMAP server hostnames this tool is allowed to connect to. */
    hosts: string[];
  };

  /**
   * Opens a connection to an IMAP server and authenticates.
   *
   * @param options - Server address, port, TLS setting, and credentials
   * @returns An opaque session handle for subsequent operations
   * @throws If the host is not in the declared hosts list, connection fails, or auth fails
   */
  abstract connect(options: ImapConnectOptions): Promise<ImapSession>;

  /**
   * Lists all mailboxes (folders) on the server.
   *
   * @param session - Session handle from connect()
   * @returns Array of mailbox descriptors
   */
  abstract listMailboxes(session: ImapSession): Promise<ImapMailbox[]>;

  /**
   * Selects a mailbox for subsequent search/fetch/flag operations.
   *
   * @param session - Session handle from connect()
   * @param mailbox - Mailbox name (e.g. "INBOX")
   * @returns Mailbox status including message count and UID validity
   */
  abstract selectMailbox(
    session: ImapSession,
    mailbox: string
  ): Promise<ImapMailboxStatus>;

  /**
   * Searches for messages matching the given criteria in the selected mailbox.
   *
   * All criteria fields are ANDed together. Returns UIDs (not sequence numbers).
   *
   * @param session - Session handle from connect()
   * @param criteria - Search criteria (all optional, ANDed)
   * @returns Array of matching message UIDs
   */
  abstract search(
    session: ImapSession,
    criteria: ImapSearchCriteria
  ): Promise<number[]>;

  /**
   * Fetches message data for the given UIDs.
   *
   * By default fetches headers only. Set `body: true` in options to include
   * message body content. The implementation handles MIME decoding internally.
   *
   * @param session - Session handle from connect()
   * @param uids - Array of message UIDs to fetch
   * @param options - What to fetch (headers, body, body type)
   * @returns Array of message objects with requested fields populated
   */
  abstract fetchMessages(
    session: ImapSession,
    uids: number[],
    options?: ImapFetchOptions
  ): Promise<ImapMessage[]>;

  /**
   * Modifies flags on messages.
   *
   * Common flags: "\\Seen" (read), "\\Flagged" (starred), "\\Deleted" (marked for deletion).
   *
   * @param session - Session handle from connect()
   * @param uids - Array of message UIDs to modify
   * @param flags - Flags to add/remove/set (e.g. ["\\Seen"])
   * @param operation - "add", "remove", or "set" (replace all flags)
   */
  abstract setFlags(
    session: ImapSession,
    uids: number[],
    flags: string[],
    operation: ImapFlagOperation
  ): Promise<void>;

  /**
   * Closes the IMAP connection.
   *
   * Always call this when done, preferably in a finally block.
   *
   * @param session - Session handle from connect()
   */
  abstract disconnect(session: ImapSession): Promise<void>;
}
