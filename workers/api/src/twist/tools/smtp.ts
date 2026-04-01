import type {
  Smtp as ISmtp,
  SmtpSession,
  SmtpConnectOptions,
  SmtpMessage,
  SmtpSendResult,
  SmtpAddress,
} from "@plotday/twister/tools/smtp";
import { type ToolPermission } from "../permissions";
import { Tool } from "./tool";

export type SmtpOptions = {
  hosts?: string[];
};

type SmtpConnection = {
  socket: { close(): void; readable: ReadableStream; writable: WritableStream };
  writer: WritableStreamDefaultWriter<Uint8Array>;
  reader: ReadableStreamDefaultReader<Uint8Array>;
  buffer: string;
  extensions: string[];
};

/**
 * Built-in tool for SMTP email sending.
 * Uses Cloudflare Workers connect() API for TCP/TLS sockets.
 */
export class Smtp extends Tool implements ISmtp {
  private hosts: string[];
  private sessions = new Map<string, SmtpConnection>();

  static Permissions(options?: SmtpOptions): ToolPermission[] {
    const hosts = options?.hosts || [];
    return hosts.map((host) => ({
      domain: "smtp",
      entity: host,
      flags: ["use"] as const,
    }));
  }

  constructor(options?: SmtpOptions) {
    super();
    this.hosts = options?.hosts || [];
  }

  async connect(options: SmtpConnectOptions): Promise<SmtpSession> {
    if (!this.hosts.includes(options.host)) {
      throw new Error(
        `SMTP host "${options.host}" is not in the declared hosts list. ` +
          `Declared hosts: ${this.hosts.join(", ")}`
      );
    }

    const useImplicitTls = options.tls && !options.starttls;

    // @ts-ignore - Cloudflare Workers connect() API for TCP sockets
    const socket = await connect(`${options.host}:${options.port}`, {
      secureTransport: useImplicitTls ? "on" : options.starttls ? "starttls" : "off",
    });

    const writer = socket.writable.getWriter();
    const reader = socket.readable.getReader();

    const sessionId = crypto.randomUUID();
    const conn: SmtpConnection = {
      socket,
      writer,
      reader,
      buffer: "",
      extensions: [],
    };

    this.sessions.set(sessionId, conn);

    // Read server greeting
    const greeting = await this.readResponse(conn);
    if (greeting.code !== 220) {
      await this.destroySession(sessionId);
      throw new Error(`SMTP server rejected connection: ${greeting.lines.join(" ")}`);
    }

    // Send EHLO
    conn.extensions = await this.sendEhlo(conn);

    // STARTTLS upgrade
    if (options.starttls) {
      const starttlsResp = await this.sendCommand(conn, "STARTTLS");
      if (starttlsResp.code !== 220) {
        await this.destroySession(sessionId);
        throw new Error(`STARTTLS failed: ${starttlsResp.lines.join(" ")}`);
      }

      // Upgrade to TLS
      conn.writer.releaseLock();
      conn.reader.releaseLock();
      // @ts-ignore - Cloudflare Workers startTls() API
      const tlsSocket = socket.startTls();
      conn.socket = tlsSocket;
      conn.writer = tlsSocket.writable.getWriter();
      conn.reader = tlsSocket.readable.getReader();
      conn.buffer = "";

      // Re-EHLO over TLS
      conn.extensions = await this.sendEhlo(conn);
    }

    // AUTH LOGIN
    const authResp = await this.sendCommand(conn, "AUTH LOGIN");
    if (authResp.code !== 334) {
      await this.destroySession(sessionId);
      throw new Error(`AUTH LOGIN failed: ${authResp.lines.join(" ")}`);
    }

    const userResp = await this.sendCommand(conn, btoa(options.username));
    if (userResp.code !== 334) {
      await this.destroySession(sessionId);
      throw new Error(`SMTP authentication failed (username rejected)`);
    }

    const passResp = await this.sendCommand(conn, btoa(options.password));
    if (passResp.code !== 235) {
      await this.destroySession(sessionId);
      throw new Error(`SMTP authentication failed: ${passResp.lines.join(" ")}`);
    }

    return sessionId;
  }

  async send(
    session: SmtpSession,
    message: SmtpMessage
  ): Promise<SmtpSendResult> {
    const conn = this.getSession(session);

    const messageId =
      message.messageId ?? `<${crypto.randomUUID()}@plot.day>`;

    // MAIL FROM
    const mailFromResp = await this.sendCommand(
      conn,
      `MAIL FROM:<${message.from.address}>`
    );
    if (mailFromResp.code !== 250) {
      throw new Error(`MAIL FROM failed: ${mailFromResp.lines.join(" ")}`);
    }

    // RCPT TO for all recipients
    const allRecipients = [
      ...message.to,
      ...(message.cc ?? []),
      ...(message.bcc ?? []),
    ];

    const accepted: string[] = [];
    const rejected: string[] = [];

    for (const rcpt of allRecipients) {
      const rcptResp = await this.sendCommand(
        conn,
        `RCPT TO:<${rcpt.address}>`
      );
      if (rcptResp.code === 250 || rcptResp.code === 251) {
        accepted.push(rcpt.address);
      } else {
        rejected.push(rcpt.address);
      }
    }

    if (accepted.length === 0) {
      // Reset the transaction since no recipients were accepted
      await this.sendCommand(conn, "RSET");
      throw new Error(
        `All recipients were rejected: ${rejected.join(", ")}`
      );
    }

    // DATA
    const dataResp = await this.sendCommand(conn, "DATA");
    if (dataResp.code !== 354) {
      throw new Error(`DATA failed: ${dataResp.lines.join(" ")}`);
    }

    // Build and send the message
    const rawMessage = this.formatMessage(message, messageId);
    const encoder = new TextEncoder();
    await conn.writer.write(encoder.encode(rawMessage));

    // End with <CRLF>.<CRLF>
    await conn.writer.write(encoder.encode("\r\n.\r\n"));

    const endResp = await this.readResponse(conn);
    if (endResp.code !== 250) {
      throw new Error(`Message delivery failed: ${endResp.lines.join(" ")}`);
    }

    return { messageId, accepted, rejected };
  }

  async disconnect(session: SmtpSession): Promise<void> {
    const conn = this.sessions.get(session);
    if (!conn) return;

    try {
      await this.sendCommand(conn, "QUIT");
    } catch {
      // Ignore errors during quit
    }

    await this.destroySession(session);
  }

  // --- Internal helpers ---

  private getSession(session: SmtpSession): SmtpConnection {
    const conn = this.sessions.get(session);
    if (!conn) {
      throw new Error(`Invalid or expired SMTP session: ${session}`);
    }
    return conn;
  }

  private async destroySession(session: SmtpSession): Promise<void> {
    const conn = this.sessions.get(session);
    if (!conn) return;

    try {
      conn.writer.releaseLock();
      conn.reader.releaseLock();
      conn.socket.close();
    } catch {
      // Ignore close errors
    }

    this.sessions.delete(session);
  }

  private async sendCommand(
    conn: SmtpConnection,
    command: string
  ): Promise<{ code: number; lines: string[] }> {
    const encoder = new TextEncoder();
    await conn.writer.write(encoder.encode(`${command}\r\n`));
    return this.readResponse(conn);
  }

  private async readResponse(
    conn: SmtpConnection
  ): Promise<{ code: number; lines: string[] }> {
    const lines: string[] = [];

    while (true) {
      const line = await this.readLine(conn);
      lines.push(line);

      // SMTP multiline: "250-..." continues, "250 ..." is final
      if (line.length >= 4 && line[3] === " ") {
        const code = parseInt(line.substring(0, 3), 10);
        return { code, lines };
      }

      // Also handle lines that are just the code (e.g. "250")
      if (line.length === 3 && /^\d{3}$/.test(line)) {
        const code = parseInt(line, 10);
        return { code, lines };
      }
    }
  }

  private async readLine(conn: SmtpConnection): Promise<string> {
    const decoder = new TextDecoder();

    while (true) {
      const newlineIdx = conn.buffer.indexOf("\r\n");
      if (newlineIdx !== -1) {
        const line = conn.buffer.substring(0, newlineIdx);
        conn.buffer = conn.buffer.substring(newlineIdx + 2);
        return line;
      }

      const { value, done } = await conn.reader.read();
      if (done) {
        throw new Error("SMTP connection closed unexpectedly");
      }

      conn.buffer += decoder.decode(value, { stream: true });
    }
  }

  private async sendEhlo(conn: SmtpConnection): Promise<string[]> {
    const resp = await this.sendCommand(conn, "EHLO plot.day");
    if (resp.code !== 250) {
      throw new Error(`EHLO failed: ${resp.lines.join(" ")}`);
    }

    // Parse extensions from multiline response (skip first line which is the greeting)
    return resp.lines
      .slice(1)
      .map((line) => line.substring(4).trim())
      .filter(Boolean);
  }

  private formatAddress(addr: SmtpAddress): string {
    if (addr.name) {
      // Escape quotes in display name
      const escapedName = addr.name.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
      return `"${escapedName}" <${addr.address}>`;
    }
    return `<${addr.address}>`;
  }

  private formatAddressList(addrs: SmtpAddress[]): string {
    return addrs.map((a) => this.formatAddress(a)).join(", ");
  }

  private formatMessage(message: SmtpMessage, messageId: string): string {
    const lines: string[] = [];

    // Date header (RFC 2822 format)
    lines.push(`Date: ${new Date().toUTCString()}`);

    // Address headers
    lines.push(`From: ${this.formatAddress(message.from)}`);
    lines.push(`To: ${this.formatAddressList(message.to)}`);

    if (message.cc && message.cc.length > 0) {
      lines.push(`Cc: ${this.formatAddressList(message.cc)}`);
    }

    if (message.replyTo) {
      lines.push(`Reply-To: ${this.formatAddress(message.replyTo)}`);
    }

    // Threading headers
    if (message.inReplyTo) {
      lines.push(`In-Reply-To: ${message.inReplyTo}`);
    }
    if (message.references && message.references.length > 0) {
      lines.push(`References: ${message.references.join(" ")}`);
    }

    // Message-ID and Subject
    lines.push(`Message-ID: ${messageId}`);
    lines.push(`Subject: ${message.subject}`);
    lines.push("MIME-Version: 1.0");

    const hasText = message.text != null;
    const hasHtml = message.html != null;

    if (hasText && hasHtml) {
      // Multipart message
      const boundary = `----=_Part_${crypto.randomUUID().replace(/-/g, "")}`;
      lines.push(
        `Content-Type: multipart/alternative; boundary="${boundary}"`
      );
      lines.push("");

      // Text part
      lines.push(`--${boundary}`);
      lines.push("Content-Type: text/plain; charset=utf-8");
      lines.push("Content-Transfer-Encoding: 7bit");
      lines.push("");
      lines.push(this.dotStuff(message.text!));

      // HTML part
      lines.push(`--${boundary}`);
      lines.push("Content-Type: text/html; charset=utf-8");
      lines.push("Content-Transfer-Encoding: 7bit");
      lines.push("");
      lines.push(this.dotStuff(message.html!));

      // Closing boundary
      lines.push(`--${boundary}--`);
    } else if (hasHtml) {
      lines.push("Content-Type: text/html; charset=utf-8");
      lines.push("Content-Transfer-Encoding: 7bit");
      lines.push("");
      lines.push(this.dotStuff(message.html!));
    } else {
      lines.push("Content-Type: text/plain; charset=utf-8");
      lines.push("Content-Transfer-Encoding: 7bit");
      lines.push("");
      lines.push(this.dotStuff(message.text ?? ""));
    }

    return lines.join("\r\n");
  }

  /**
   * SMTP dot-stuffing: lines that start with a period must have
   * an extra period prepended to avoid being interpreted as the
   * end-of-data marker.
   */
  private dotStuff(text: string): string {
    return text.replace(/^\.(?=.)/gm, "..");
  }
}
