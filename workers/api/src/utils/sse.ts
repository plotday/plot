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

  const data = typeof message.data === 'string'
    ? message.data
    : JSON.stringify(message.data);

  lines.push(`data: ${data}`);
  lines.push(''); // Empty line to mark end of message

  return lines.join('\n') + '\n';
}

/**
 * Create a streaming SSE response
 */
export class SSEStream {
  private encoder = new TextEncoder();
  private controller: ReadableStreamDefaultController | null = null;
  private closed = false;

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
    this.send({ event: 'progress', data: { message } });
  }

  /**
   * Send the final result
   */
  sendResult(data: any): void {
    this.send({ event: 'result', data });
  }

  /**
   * Send an error
   */
  sendError(error: string): void {
    this.send({ event: 'error', data: { error } });
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
   * Close the stream
   */
  close(): void {
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
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'Connection': 'keep-alive',
      },
    });
  }
}

/**
 * Check if the request accepts SSE streaming
 */
export function acceptsSSE(request: Request): boolean {
  const accept = request.headers.get('Accept') || '';
  return accept.includes('text/event-stream');
}
