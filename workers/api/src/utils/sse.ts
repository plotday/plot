/**
 * Server-Sent Events (SSE) utilities for streaming responses
 */

export interface SSEMessage {
  event?: string;
  data: any;
  id?: string;
}

/**
 * Format a message as SSE format
 */
function formatSSEMessage(message: SSEMessage): string {
  const lines: string[] = [];

  if (message.id) {
    lines.push(`id: ${message.id}`);
  }

  if (message.event) {
    lines.push(`event: ${message.event}`);
  }

  const data =
    typeof message.data === "string"
      ? message.data
      : JSON.stringify(message.data);

  lines.push(`data: ${data}`);
  lines.push(""); // Empty line to mark end of message

  return lines.join("\n") + "\n";
}

/**
 * Create a streaming SSE response
 */
export class SSEStream {
  private encoder = new TextEncoder();
  private controller: ReadableStreamDefaultController | null = null;
  private closed = false;
  private heartbeatTimer: ReturnType<typeof setInterval> | null = null;

  readonly stream: ReadableStream;

  constructor() {
    this.stream = new ReadableStream({
      start: (controller) => {
        this.controller = controller;
      },
      cancel: () => {
        this.closed = true;
      },
    });
  }

  /**
   * Send a progress update
   */
  sendProgress(message: string): void {
    this.send({ event: "progress", data: { message } });
  }

  /**
   * Send the final result
   */
  sendResult(data: any): void {
    this.send({ event: "result", data });
  }

  /**
   * Send an error
   */
  sendError(error: string): void {
    this.send({ event: "error", data: { error } });
  }

  /**
   * Send a custom SSE message
   */
  send(message: SSEMessage): void {
    if (this.closed || !this.controller) {
      return;
    }

    const formatted = formatSSEMessage(message);
    this.controller.enqueue(this.encoder.encode(formatted));
  }

  /**
   * Send an SSE comment line. Comments (lines starting with ":") are ignored by
   * SSE clients but still arrive as bytes on the wire, which resets a client's
   * read-inactivity timeout. Node's global fetch (undici) aborts a body read
   * after 300s of silence with a generic network error, so a long server-side
   * operation that emits no events for >300s looks like a dropped connection.
   */
  sendComment(text = ""): void {
    if (this.closed || !this.controller) {
      return;
    }

    this.controller.enqueue(this.encoder.encode(`:${text}\n\n`));
  }

  /**
   * Begin sending periodic heartbeat comments so the connection stays alive
   * during long operations that emit no progress (e.g. upgrading thousands of
   * active twist instances). The interval is cleared on close() or
   * stopHeartbeat(). Calling more than once is a no-op while one is running.
   */
  startHeartbeat(intervalMs = 15000): void {
    if (this.heartbeatTimer || this.closed) {
      return;
    }

    this.heartbeatTimer = setInterval(() => {
      this.sendComment("heartbeat");
    }, intervalMs);
  }

  /**
   * Stop the periodic heartbeat started by startHeartbeat().
   */
  stopHeartbeat(): void {
    if (this.heartbeatTimer) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = null;
    }
  }

  /**
   * Close the stream
   */
  close(): void {
    this.stopHeartbeat();

    if (this.closed || !this.controller) {
      return;
    }

    this.closed = true;
    this.controller.close();
  }

  /**
   * Create a Response object from this stream
   */
  toResponse(): Response {
    return new Response(this.stream, {
      headers: {
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
        Connection: "keep-alive",
      },
    });
  }
}

/**
 * Check if the request accepts SSE streaming
 */
export function acceptsSSE(request: Request): boolean {
  const accept = request.headers.get("Accept") || "";
  return accept.includes("text/event-stream");
}
