import { DurableObject } from "cloudflare:workers";

import type { Bindings, LogMessage } from "../env";
import { createLogger } from "@plotday/worker-util";

/**
 * Durable Object for streaming twist logs via SSE.
 * Each instance manages SSE streams for a specific twist.
 */
export class LogStream extends DurableObject<Bindings> {
  private streams: Map<string, ReadableStreamDefaultController> = new Map();
  private keepAliveInterval = 30000; // 30 seconds

  constructor(ctx: DurableObjectState, env: Bindings) {
    super(ctx, env);
  }

  /**
   * Alarm handler - sends keep-alive pings to maintain SSE connections
   */
  async alarm(): Promise<void> {
    const logger = createLogger({
      durable_object: "LogStream",
      operation: "alarm",
    });

    // Send ping to all active streams
    const encoder = new TextEncoder();
    const ping = encoder.encode(":ping\n\n");

    for (const controller of this.streams.values()) {
      try {
        controller.enqueue(ping);
      } catch (error) {
        logger.error("Error sending keep-alive ping", error as Error);
      }
    }

    // Schedule next alarm if we still have active streams
    if (this.streams.size > 0) {
      await this.ctx.storage.setAlarm(Date.now() + this.keepAliveInterval);
    }
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const streamId = url.searchParams.get("streamId");

    if (!streamId) {
      return new Response("Missing streamId", { status: 400 });
    }

    // Create SSE stream
    const stream = new ReadableStream({
      start: async (c) => {
        // Store this controller so we can send logs to it
        this.streams.set(streamId, c);

        // Schedule keep-alive alarm if this is the first stream
        if (this.streams.size === 1) {
          await this.ctx.storage.setAlarm(Date.now() + this.keepAliveInterval);
        }
      },
      cancel: async () => {
        // Clean up when client disconnects
        this.streams.delete(streamId);

        // Cancel alarm if this was the last stream
        if (this.streams.size === 0) {
          await this.ctx.storage.deleteAlarm();
        }
      },
    });

    return new Response(stream, {
      headers: {
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
        Connection: "keep-alive",
      },
    });
  }

  /**
   * Called by the queue processor to send logs to all active streams
   */
  async sendLogs(logs: LogMessage[]): Promise<void> {
    const logger = createLogger({
      durable_object: "LogStream",
      operation: "sendLogs",
    });

    const encoder = new TextEncoder();

    for (const log of logs) {
      const message = this.formatSSE({
        event: "log",
        data: {
          timestamp: new Date(log.timestamp).toISOString(),
          severity: log.severity,
          message: log.message,
          environment: log.environment,
        },
      });

      const encoded = encoder.encode(message);

      // Send to all active streams
      for (const controller of this.streams.values()) {
        try {
          controller.enqueue(encoded);
        } catch (error) {
          logger.error("Error sending log to stream", error as Error);
        }
      }
    }
  }

  /**
   * Format a message in SSE format
   */
  private formatSSE(message: {
    event?: string;
    data: any;
    id?: string;
  }): string {
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
}
