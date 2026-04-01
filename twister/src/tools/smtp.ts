import { ITool } from "..";

/** Opaque session handle returned by connect(). */
export type SmtpSession = string;

/** Credentials and server info for connecting to an SMTP server. */
export type SmtpConnectOptions = {
  /** SMTP server hostname (e.g. "smtp.mail.me.com") */
  host: string;
  /** SMTP server port (e.g. 465 for TLS, 587 for STARTTLS) */
  port: number;
  /** Whether to use implicit TLS (true for port 465) */
  tls: boolean;
  /** Whether to upgrade to TLS via STARTTLS (true for port 587) */
  starttls: boolean;
  /** SMTP username (typically the email address) */
  username: string;
  /** SMTP password (app-specific password for Apple) */
  password: string;
};

/** An email address with optional display name. */
export type SmtpAddress = {
  /** Display name (e.g. "John Doe") */
  name?: string;
  /** Email address (e.g. "john@example.com") */
  address: string;
};

/** An email message to send. */
export type SmtpMessage = {
  /** Sender address */
  from: SmtpAddress;
  /** Primary recipients */
  to: SmtpAddress[];
  /** Carbon copy recipients */
  cc?: SmtpAddress[];
  /** Blind carbon copy recipients (not visible in headers) */
  bcc?: SmtpAddress[];
  /** Reply-To address (if different from From) */
  replyTo?: SmtpAddress;
  /** Message-ID of the message being replied to (for threading) */
  inReplyTo?: string;
  /** Message-ID chain for threading */
  references?: string[];
  /** Email subject line */
  subject: string;
  /** Plain text body */
  text?: string;
  /** HTML body */
  html?: string;
  /** Custom Message-ID; auto-generated as <uuid@plot.day> if omitted */
  messageId?: string;
};

/** Result of sending an email. */
export type SmtpSendResult = {
  /** The Message-ID that was used (auto-generated or from SmtpMessage) */
  messageId: string;
  /** Email addresses that were accepted by the server */
  accepted: string[];
  /** Email addresses that were rejected by the server */
  rejected: string[];
};

/**
 * Built-in tool for SMTP email sending.
 *
 * Provides high-level SMTP operations for composing and sending email.
 * Handles TCP/TLS connections, STARTTLS upgrades, SMTP protocol details,
 * and RFC 2822 message formatting internally.
 *
 * **Permission model:** Connectors declare which SMTP hosts they need access
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
 *       smtp: build(Smtp, { hosts: ["smtp.mail.me.com"] }),
 *       integrations: build(Integrations),
 *     };
 *   }
 *
 *   async sendReply(originalMessage: ImapMessage, replyBody: string) {
 *     const session = await this.tools.smtp.connect({
 *       host: "smtp.mail.me.com",
 *       port: 587,
 *       tls: false,
 *       starttls: true,
 *       username: this.tools.options.email,
 *       password: this.tools.options.password,
 *     });
 *
 *     try {
 *       const result = await this.tools.smtp.send(session, {
 *         from: { address: this.tools.options.email },
 *         to: originalMessage.from ?? [],
 *         subject: `Re: ${originalMessage.subject ?? "(no subject)"}`,
 *         text: replyBody,
 *         inReplyTo: originalMessage.messageId,
 *         references: [
 *           ...(originalMessage.references ?? []),
 *           ...(originalMessage.messageId ? [originalMessage.messageId] : []),
 *         ],
 *       });
 *
 *       console.log(`Sent reply, Message-ID: ${result.messageId}`);
 *     } finally {
 *       await this.tools.smtp.disconnect(session);
 *     }
 *   }
 * }
 * ```
 */
export abstract class Smtp extends ITool {
  static readonly Options: {
    /** SMTP server hostnames this tool is allowed to connect to. */
    hosts: string[];
  };

  /**
   * Opens a connection to an SMTP server and authenticates.
   *
   * Handles the full SMTP handshake: greeting, EHLO, optional STARTTLS
   * upgrade, and AUTH LOGIN authentication.
   *
   * @param options - Server address, port, TLS/STARTTLS setting, and credentials
   * @returns An opaque session handle for subsequent operations
   * @throws If the host is not in the declared hosts list, connection fails, or auth fails
   */
  abstract connect(options: SmtpConnectOptions): Promise<SmtpSession>;

  /**
   * Sends an email message.
   *
   * Constructs a properly formatted RFC 2822 message with MIME support
   * and sends it via the SMTP protocol. Handles multipart messages when
   * both text and HTML bodies are provided.
   *
   * @param session - Session handle from connect()
   * @param message - The email message to send
   * @returns Send result with Message-ID and per-recipient acceptance status
   * @throws If the session is invalid or the server rejects the message entirely
   */
  abstract send(
    session: SmtpSession,
    message: SmtpMessage
  ): Promise<SmtpSendResult>;

  /**
   * Closes the SMTP connection.
   *
   * Always call this when done, preferably in a finally block.
   *
   * @param session - Session handle from connect()
   */
  abstract disconnect(session: SmtpSession): Promise<void>;
}
