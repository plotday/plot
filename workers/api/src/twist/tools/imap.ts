import type {
  Imap as IImap,
  ImapSession,
  ImapConnectOptions,
  ImapMailbox,
  ImapMailboxStatus,
  ImapSearchCriteria,
  ImapMessage,
  ImapFetchOptions,
  ImapFlagOperation,
} from "@plotday/twister/tools/imap";
import { type ToolPermission } from "../permissions";
import { Tool } from "./tool";

export type ImapOptions = {
  hosts?: string[];
};

type ImapConnection = {
  socket: { close(): void; readable: ReadableStream; writable: WritableStream };
  writer: WritableStreamDefaultWriter<Uint8Array>;
  reader: ReadableStreamDefaultReader<Uint8Array>;
  tagCounter: number;
  buffer: string;
  selectedMailbox: string | null;
};

/**
 * Built-in tool for IMAP email access.
 * Uses Cloudflare Workers connect() API for TCP/TLS sockets.
 */
export class Imap extends Tool implements IImap {
  private hosts: string[];
  private sessions = new Map<string, ImapConnection>();

  static Permissions(options?: ImapOptions): ToolPermission[] {
    const hosts = options?.hosts || [];
    return hosts.map((host) => ({
      domain: "imap",
      entity: host,
      flags: ["use"] as const,
    }));
  }

  constructor(options?: ImapOptions) {
    super();
    this.hosts = options?.hosts || [];
  }

  async connect(options: ImapConnectOptions): Promise<ImapSession> {
    if (!this.hosts.includes(options.host)) {
      throw new Error(
        `IMAP host "${options.host}" is not in the declared hosts list. ` +
          `Declared hosts: ${this.hosts.join(", ")}`
      );
    }

    // @ts-ignore - Cloudflare Workers connect() API for TCP sockets
    const socket = await connect(`${options.host}:${options.port}`, {
      secureTransport: options.tls ? "on" : "off",
    });

    const writer = socket.writable.getWriter();
    const reader = socket.readable.getReader();

    const sessionId = crypto.randomUUID();
    const conn: ImapConnection = {
      socket,
      writer,
      reader,
      tagCounter: 0,
      buffer: "",
      selectedMailbox: null,
    };

    this.sessions.set(sessionId, conn);

    // Read server greeting
    const greeting = await this.readLine(conn);
    if (!greeting.startsWith("* OK")) {
      await this.destroySession(sessionId);
      throw new Error(`IMAP server rejected connection: ${greeting}`);
    }

    // Authenticate with LOGIN
    const loginResp = await this.sendCommand(
      conn,
      `LOGIN ${this.quoteString(options.username)} ${this.quoteString(options.password)}`
    );
    if (!loginResp.ok) {
      await this.destroySession(sessionId);
      throw new Error(`IMAP authentication failed: ${loginResp.text}`);
    }

    return sessionId;
  }

  async listMailboxes(session: ImapSession): Promise<ImapMailbox[]> {
    const conn = this.getSession(session);
    const resp = await this.sendCommand(conn, 'LIST "" "*"');
    if (!resp.ok) {
      throw new Error(`LIST failed: ${resp.text}`);
    }

    return resp.untagged
      .filter((line) => line.startsWith("* LIST "))
      .map((line) => this.parseListResponse(line));
  }

  async selectMailbox(
    session: ImapSession,
    mailbox: string
  ): Promise<ImapMailboxStatus> {
    const conn = this.getSession(session);
    const resp = await this.sendCommand(
      conn,
      `SELECT ${this.quoteString(mailbox)}`
    );
    if (!resp.ok) {
      throw new Error(`SELECT failed: ${resp.text}`);
    }

    conn.selectedMailbox = mailbox;
    return this.parseSelectResponse(mailbox, resp.untagged);
  }

  async search(
    session: ImapSession,
    criteria: ImapSearchCriteria
  ): Promise<number[]> {
    const conn = this.getSession(session);
    if (!conn.selectedMailbox) {
      throw new Error("No mailbox selected. Call selectMailbox() first.");
    }

    const searchArgs = this.buildSearchArgs(criteria);
    const resp = await this.sendCommand(conn, `UID SEARCH ${searchArgs}`);
    if (!resp.ok) {
      throw new Error(`SEARCH failed: ${resp.text}`);
    }

    const searchLine = resp.untagged.find((l) => l.startsWith("* SEARCH"));
    if (!searchLine || searchLine === "* SEARCH") {
      return [];
    }

    return searchLine
      .substring("* SEARCH ".length)
      .trim()
      .split(/\s+/)
      .map(Number)
      .filter((n) => !isNaN(n));
  }

  async fetchMessages(
    session: ImapSession,
    uids: number[],
    options?: ImapFetchOptions
  ): Promise<ImapMessage[]> {
    if (uids.length === 0) return [];

    const conn = this.getSession(session);
    if (!conn.selectedMailbox) {
      throw new Error("No mailbox selected. Call selectMailbox() first.");
    }

    const fetchHeaders = options?.headers !== false;
    const fetchBody = options?.body === true;
    const bodyType = options?.bodyType ?? "both";

    const items: string[] = ["UID", "FLAGS", "RFC822.SIZE"];
    if (fetchHeaders) {
      items.push("ENVELOPE");
    }
    if (fetchBody) {
      items.push("BODY.PEEK[TEXT]");
      items.push("BODYSTRUCTURE");
    }

    const uidSet = uids.join(",");
    const resp = await this.sendCommand(
      conn,
      `UID FETCH ${uidSet} (${items.join(" ")})`
    );
    if (!resp.ok) {
      throw new Error(`FETCH failed: ${resp.text}`);
    }

    return this.parseFetchResponses(
      resp.untagged,
      fetchHeaders,
      fetchBody,
      bodyType
    );
  }

  async setFlags(
    session: ImapSession,
    uids: number[],
    flags: string[],
    operation: ImapFlagOperation
  ): Promise<void> {
    if (uids.length === 0) return;

    const conn = this.getSession(session);
    if (!conn.selectedMailbox) {
      throw new Error("No mailbox selected. Call selectMailbox() first.");
    }

    const uidSet = uids.join(",");
    const flagList = `(${flags.join(" ")})`;

    const prefix =
      operation === "add" ? "+" : operation === "remove" ? "-" : "";
    const storeCmd = `UID STORE ${uidSet} ${prefix}FLAGS ${flagList}`;

    const resp = await this.sendCommand(conn, storeCmd);
    if (!resp.ok) {
      throw new Error(`STORE failed: ${resp.text}`);
    }
  }

  async disconnect(session: ImapSession): Promise<void> {
    const conn = this.sessions.get(session);
    if (!conn) return;

    try {
      await this.sendCommand(conn, "LOGOUT");
    } catch {
      // Ignore errors during logout
    }

    await this.destroySession(session);
  }

  // --- Internal helpers ---

  private getSession(session: ImapSession): ImapConnection {
    const conn = this.sessions.get(session);
    if (!conn) {
      throw new Error(`Invalid or expired IMAP session: ${session}`);
    }
    return conn;
  }

  private async destroySession(session: ImapSession): Promise<void> {
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

  private nextTag(conn: ImapConnection): string {
    conn.tagCounter++;
    return `A${String(conn.tagCounter).padStart(4, "0")}`;
  }

  private async sendCommand(
    conn: ImapConnection,
    command: string
  ): Promise<{ ok: boolean; text: string; untagged: string[] }> {
    const tag = this.nextTag(conn);
    const line = `${tag} ${command}\r\n`;
    const encoder = new TextEncoder();
    await conn.writer.write(encoder.encode(line));

    const untagged: string[] = [];
    while (true) {
      const responseLine = await this.readLine(conn);

      if (responseLine.startsWith(`${tag} `)) {
        const rest = responseLine.substring(tag.length + 1);
        const ok = rest.startsWith("OK");
        return { ok, text: rest, untagged };
      }

      untagged.push(responseLine);
    }
  }

  private async readLine(conn: ImapConnection): Promise<string> {
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
        throw new Error("IMAP connection closed unexpectedly");
      }

      conn.buffer += decoder.decode(value, { stream: true });
    }
  }

  private quoteString(s: string): string {
    return `"${s.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
  }

  private parseListResponse(line: string): ImapMailbox {
    // Format: * LIST (\flags) "delimiter" "name"
    const flagsMatch = line.match(/\* LIST \(([^)]*)\)/);
    const flags = flagsMatch
      ? flagsMatch[1].split(/\s+/).filter(Boolean)
      : [];

    const specialUseFlags = [
      "\\Sent",
      "\\Drafts",
      "\\Trash",
      "\\Junk",
      "\\Archive",
      "\\All",
      "\\Flagged",
    ];
    const specialUse = flags.find((f) => specialUseFlags.includes(f));

    // Parse delimiter and name after the flags
    const afterFlags = line.substring(line.indexOf(")") + 2);
    const parts = afterFlags.match(/"([^"]*)" "?([^"]*)"?/);

    const delimiter = parts?.[1] ?? "/";
    let name = parts?.[2] ?? "";
    if (name.startsWith('"') && name.endsWith('"')) {
      name = name.substring(1, name.length - 1);
    }

    return { name, delimiter, flags, specialUse };
  }

  private parseSelectResponse(
    mailbox: string,
    untagged: string[]
  ): ImapMailboxStatus {
    let exists = 0;
    let recent = 0;
    let uidValidity = 0;
    let uidNext = 0;
    let unseen: number | undefined;

    for (const line of untagged) {
      const existsMatch = line.match(/\* (\d+) EXISTS/);
      if (existsMatch) exists = parseInt(existsMatch[1], 10);

      const recentMatch = line.match(/\* (\d+) RECENT/);
      if (recentMatch) recent = parseInt(recentMatch[1], 10);

      const uidValidityMatch = line.match(/UIDVALIDITY (\d+)/);
      if (uidValidityMatch)
        uidValidity = parseInt(uidValidityMatch[1], 10);

      const uidNextMatch = line.match(/UIDNEXT (\d+)/);
      if (uidNextMatch) uidNext = parseInt(uidNextMatch[1], 10);

      const unseenMatch = line.match(/UNSEEN (\d+)/);
      if (unseenMatch) unseen = parseInt(unseenMatch[1], 10);
    }

    return { name: mailbox, exists, recent, uidValidity, uidNext, unseen };
  }

  private buildSearchArgs(criteria: ImapSearchCriteria): string {
    const args: string[] = [];

    if (criteria.uid && criteria.uid.length > 0) {
      args.push(`UID ${criteria.uid.join(",")}`);
    }
    if (criteria.since) {
      args.push(`SINCE ${this.formatImapDate(criteria.since)}`);
    }
    if (criteria.before) {
      args.push(`BEFORE ${this.formatImapDate(criteria.before)}`);
    }
    if (criteria.from) {
      args.push(`FROM ${this.quoteString(criteria.from)}`);
    }
    if (criteria.to) {
      args.push(`TO ${this.quoteString(criteria.to)}`);
    }
    if (criteria.subject) {
      args.push(`SUBJECT ${this.quoteString(criteria.subject)}`);
    }
    if (criteria.unseen === true) {
      args.push("UNSEEN");
    } else if (criteria.unseen === false) {
      args.push("SEEN");
    }
    if (criteria.flagged === true) {
      args.push("FLAGGED");
    } else if (criteria.flagged === false) {
      args.push("UNFLAGGED");
    }

    return args.length > 0 ? args.join(" ") : "ALL";
  }

  private formatImapDate(date: Date | string): string {
    const d = typeof date === "string" ? new Date(date) : date;
    const months = [
      "Jan",
      "Feb",
      "Mar",
      "Apr",
      "May",
      "Jun",
      "Jul",
      "Aug",
      "Sep",
      "Oct",
      "Nov",
      "Dec",
    ];
    return `${d.getUTCDate()}-${months[d.getUTCMonth()]}-${d.getUTCFullYear()}`;
  }

  private parseFetchResponses(
    untagged: string[],
    fetchHeaders: boolean,
    fetchBody: boolean,
    bodyType: string
  ): ImapMessage[] {
    const messages: ImapMessage[] = [];

    const fullText = untagged.join("\r\n");

    // Split by FETCH response boundaries
    const fetchRegex = /\* \d+ FETCH \(/g;
    const starts: number[] = [];
    let match: RegExpExecArray | null;
    while ((match = fetchRegex.exec(fullText)) !== null) {
      starts.push(match.index);
    }

    for (let i = 0; i < starts.length; i++) {
      const start = starts[i];
      const end = i + 1 < starts.length ? starts[i + 1] : fullText.length;
      const fetchBlock = fullText.substring(start, end);

      const msg: ImapMessage = {
        uid: 0,
        flags: [],
      };

      // Parse UID
      const uidMatch = fetchBlock.match(/UID (\d+)/);
      if (uidMatch) msg.uid = parseInt(uidMatch[1], 10);

      // Parse FLAGS
      const flagsMatch = fetchBlock.match(/FLAGS \(([^)]*)\)/);
      if (flagsMatch) {
        msg.flags = flagsMatch[1].split(/\s+/).filter(Boolean);
      }

      // Parse RFC822.SIZE
      const sizeMatch = fetchBlock.match(/RFC822\.SIZE (\d+)/);
      if (sizeMatch) msg.size = parseInt(sizeMatch[1], 10);

      // Parse ENVELOPE
      if (fetchHeaders) {
        this.parseEnvelope(fetchBlock, msg);
      }

      // Parse body text
      if (fetchBody) {
        const bodyMatch = fetchBlock.match(
          /BODY\[TEXT\] \{(\d+)\}\r\n([\s\S]*)/
        );
        if (bodyMatch) {
          const bodyLength = parseInt(bodyMatch[1], 10);
          const bodyContent = bodyMatch[2].substring(0, bodyLength);

          if (bodyType === "text" || bodyType === "both") {
            msg.bodyText = this.extractTextFromMime(bodyContent, "text/plain");
          }
          if (bodyType === "html" || bodyType === "both") {
            msg.bodyHtml = this.extractTextFromMime(bodyContent, "text/html");
          }

          // Fallback: if no MIME parts found, treat as plain text
          if (!msg.bodyText && !msg.bodyHtml) {
            if (bodyType === "html" || bodyType === "both") {
              msg.bodyHtml = bodyContent;
            }
            if (bodyType === "text" || bodyType === "both") {
              msg.bodyText = bodyContent;
            }
          }
        }
      }

      if (msg.uid > 0) {
        messages.push(msg);
      }
    }

    return messages;
  }

  private parseEnvelope(fetchBlock: string, msg: ImapMessage): void {
    // Parse date (first quoted string in ENVELOPE)
    const dateMatch = fetchBlock.match(/ENVELOPE \("([^"]*?)"/);
    if (dateMatch && dateMatch[1]) {
      try {
        msg.date = new Date(dateMatch[1]);
      } catch {
        // Ignore invalid dates
      }
    }

    // Parse subject (second quoted string or NIL)
    const subjectMatch = fetchBlock.match(
      /ENVELOPE \("[^"]*" (?:"([^"]*?)"|NIL)/
    );
    if (subjectMatch && subjectMatch[1]) {
      msg.subject = this.decodeImapString(subjectMatch[1]);
    }

    // Parse Message-ID
    const msgIdMatch = fetchBlock.match(/<[^>]+>/);
    if (msgIdMatch) {
      msg.messageId = msgIdMatch[0];
    }

    // Address parsing from ENVELOPE is complex (nested parenthesized lists).
    // Initial implementation extracts Message-ID, date, and subject.
    // Full address parsing can be added when needed.
  }

  private decodeImapString(s: string): string {
    // Handle RFC 2047 encoded words: =?charset?encoding?text?=
    return s.replace(
      /=\?([^?]+)\?([BbQq])\?([^?]+)\?=/g,
      (_match, _charset, encoding, text) => {
        if (encoding.toUpperCase() === "B") {
          try {
            return atob(text);
          } catch {
            return text;
          }
        }
        if (encoding.toUpperCase() === "Q") {
          return text
            .replace(/_/g, " ")
            .replace(
              /=([0-9A-Fa-f]{2})/g,
              (_: string, hex: string) =>
                String.fromCharCode(parseInt(hex, 16))
            );
        }
        return text;
      }
    );
  }

  private extractTextFromMime(
    body: string,
    contentType: string
  ): string | undefined {
    const boundary = this.findMimeBoundary(body);

    if (!boundary) {
      // Not multipart — check if the whole body matches
      const ctMatch = body.match(/Content-Type:\s*([^\r\n;]+)/i);
      if (!ctMatch || ctMatch[1].trim().toLowerCase() === contentType) {
        const headerEnd = body.indexOf("\r\n\r\n");
        if (headerEnd !== -1) {
          return this.decodeTransferEncoding(
            body,
            body.substring(headerEnd + 4)
          );
        }
        return body;
      }
      return undefined;
    }

    // Split by boundary and find the matching part
    const parts = body.split(`--${boundary}`);
    for (const part of parts) {
      const ctMatch = part.match(/Content-Type:\s*([^\r\n;]+)/i);
      if (ctMatch && ctMatch[1].trim().toLowerCase() === contentType) {
        const headerEnd = part.indexOf("\r\n\r\n");
        if (headerEnd !== -1) {
          return this.decodeTransferEncoding(
            part,
            part.substring(headerEnd + 4)
          );
        }
      }
    }

    return undefined;
  }

  private findMimeBoundary(body: string): string | undefined {
    const match = body.match(/boundary="?([^"\r\n;]+)"?/i);
    return match?.[1];
  }

  private decodeTransferEncoding(headers: string, content: string): string {
    const encodingMatch = headers.match(
      /Content-Transfer-Encoding:\s*(\S+)/i
    );
    const encoding = encodingMatch?.[1]?.toLowerCase();

    if (encoding === "base64") {
      try {
        return atob(content.replace(/\s/g, ""));
      } catch {
        return content;
      }
    }

    if (encoding === "quoted-printable") {
      return content
        .replace(/=\r\n/g, "")
        .replace(
          /=([0-9A-Fa-f]{2})/g,
          (_: string, hex: string) =>
            String.fromCharCode(parseInt(hex, 16))
        );
    }

    return content;
  }
}
