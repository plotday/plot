import { DurableObject } from "cloudflare:workers";
import { PostHog } from "posthog-node";

import type { Bindings } from "../env";
import { createLogger } from "@plotday/worker-util";
import { verifyToken } from "@clerk/backend";

interface QueuedMessage {
  message: any;
  clientId?: string;
  timestamp: number;
}

export class Broadcast extends DurableObject<Bindings> {
  private connections: Map<string, WebSocket> = new Map();
  /** Clients that have sent `active: false` (app backgrounded). */
  private inactiveClients: Set<string> = new Set();
  private messageQueue: QueuedMessage[] = [];
  private lastMessageTime: number = 0;
  private batchTimeout: ReturnType<typeof setTimeout> | null = null;
  private userId: string | null = null;
  // Track last DB write time per client to rate-limit activity writes to 1/minute
  private lastActivityWrite: Map<string, number> = new Map();
  private activityTablesReady = false;

  constructor(ctx: DurableObjectState, env: Bindings) {
    super(ctx, env);
    // User ID will be set during first authentication
  }

  private captureException(error: Error, properties?: Record<string, unknown>) {
    const postHog = new PostHog(this.env.POSTHOG_API_KEY, {
      host: this.env.POSTHOG_HOST,
      flushAt: 1,
      flushInterval: 0,
    });
    postHog.captureException(error, this.userId ?? undefined, {
      durable_object: "Broadcast",
      ...properties,
    });
    this.ctx.waitUntil(postHog.shutdown());
  }

  private ensureActivityTables(): void {
    if (this.activityTablesReady) return;
    // Per-client and EPHEMERAL: rows are deleted when a device disconnects
    // (see removeDeviceActivity). Drives `/last-active` (push gating) and
    // `/others-active` (cross-device suppression), which both ask "which
    // devices are connected and active right now".
    this.ctx.storage.sql.exec(
      "CREATE TABLE IF NOT EXISTS device_activity (client_id TEXT PRIMARY KEY, last_active_at INTEGER)"
    );
    // A single per-user timestamp that PERSISTS across disconnects. Drives
    // `/last-active-persisted` (email gating), which asks "was the user active
    // at any point since the notification was queued" — inherently historical,
    // so it must survive the app closing. See email-notify.ts.
    this.ctx.storage.sql.exec(
      "CREATE TABLE IF NOT EXISTS user_activity (id INTEGER PRIMARY KEY, last_active_at INTEGER)"
    );
    this.activityTablesReady = true;
  }

  private removeDeviceActivity(clientId: string): void {
    this.ensureActivityTables();
    // Only clears the ephemeral per-device row. The persisted `user_activity`
    // timestamp is intentionally left untouched so email gating still knows
    // the user was recently active even after every device disconnects.
    this.ctx.storage.sql.exec(
      "DELETE FROM device_activity WHERE client_id = ?",
      clientId
    );
    this.lastActivityWrite.delete(clientId);
  }

  private maybeRecordActivity(clientId: string): void {
    const now = Date.now();
    const lastWrite = this.lastActivityWrite.get(clientId) ?? 0;
    if (now - lastWrite < 60_000) return; // rate-limit: 1 write/minute per client
    this.lastActivityWrite.set(clientId, now);
    this.ensureActivityTables();
    // Ephemeral per-client activity (cleared on disconnect).
    this.ctx.storage.sql.exec(
      "INSERT OR REPLACE INTO device_activity (client_id, last_active_at) VALUES (?, ?)",
      clientId,
      now
    );
    // Persisted per-user activity (survives disconnect). Kept monotonic so a
    // late write from a slower client can't move the timestamp backwards.
    this.ctx.storage.sql.exec(
      "INSERT INTO user_activity (id, last_active_at) VALUES (0, ?) " +
        "ON CONFLICT (id) DO UPDATE SET last_active_at = MAX(user_activity.last_active_at, excluded.last_active_at)",
      now
    );
  }

  async fetch(request: Request): Promise<Response> {
    if (request.headers.get("Upgrade") === "websocket") {
      return this.handleWebSocket(request);
    }

    const url = new URL(request.url);
    if (url.pathname === "/hasConnectedClients" && request.method === "GET") {
      return Response.json({ hasConnectedClients: this.hasConnectedClients() });
    }

    if (url.pathname === "/last-active" && request.method === "GET") {
      // Most recent activity among CURRENTLY-CONNECTED devices (rows are
      // dropped on disconnect). Push gating wants this real-time view: once
      // the user closes the app, pushes should flow to their other devices.
      this.ensureActivityTables();
      const cursor = this.ctx.storage.sql.exec(
        "SELECT MAX(last_active_at) AS max_active FROM device_activity"
      );
      const rows = [...cursor];
      const maxActive = rows[0]?.max_active as number | null | undefined;
      return Response.json({
        lastActiveAt: maxActive != null ? new Date(maxActive).toISOString() : null,
      });
    }

    if (
      url.pathname === "/last-active-persisted" &&
      request.method === "GET"
    ) {
      // Last time ANY of the user's devices was active, persisted across
      // disconnects. Unlike `/last-active`, closing the app does not reset
      // this — email gating needs to know whether the user opened Plot at any
      // point since a notification was queued (often many hours earlier).
      this.ensureActivityTables();
      const cursor = this.ctx.storage.sql.exec(
        "SELECT last_active_at FROM user_activity WHERE id = 0"
      );
      const rows = [...cursor];
      const lastActive = rows[0]?.last_active_at as number | null | undefined;
      return Response.json({
        lastActiveAt:
          lastActive != null ? new Date(lastActive).toISOString() : null,
      });
    }

    if (url.pathname === "/others-active" && request.method === "GET") {
      const excludeClient = url.searchParams.get("excludeClient") ?? "";
      this.ensureActivityTables();
      // Clean up stale entries for clients that are no longer connected
      const allCursor = this.ctx.storage.sql.exec(
        "SELECT client_id FROM device_activity"
      );
      const allClientIds = [...allCursor] as { client_id: string }[];
      for (const row of allClientIds) {
        if (!this.connections.has(row.client_id)) {
          this.ctx.storage.sql.exec(
            "DELETE FROM device_activity WHERE client_id = ?",
            row.client_id
          );
        }
      }
      const cursor = this.ctx.storage.sql.exec(
        "SELECT MAX(last_active_at) AS max_active FROM device_activity WHERE client_id != ?",
        excludeClient
      );
      const rows = [...cursor];
      const maxActive = rows[0]?.max_active as number | null | undefined;
      const lastActiveAt = maxActive != null
        ? new Date(maxActive).toISOString()
        : null;
      return Response.json({ lastActiveAt });
    }

    return new Response("Not found", { status: 404 });
  }

  private async handleWebSocket(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const clientId = url.searchParams.get("clientId");
    const clientVersion = url.searchParams.get("clientVersion");
    const clientPlatform = url.searchParams.get("clientPlatform");

    // Extract userId from the URL path
    const pathParts = url.pathname.split("/");
    const userIdFromPath = pathParts[pathParts.length - 1];

    if (!clientId) {
      return new Response("Missing clientId parameter", { status: 400 });
    }

    if (!userIdFromPath) {
      return new Response("Missing userId in path", { status: 400 });
    }

    // Extract token from Sec-WebSocket-Protocol header
    const protocols = request.headers.get("Sec-WebSocket-Protocol");
    if (!protocols) {
      return new Response("Missing Sec-WebSocket-Protocol header", {
        status: 401,
      });
    }

    // Parse protocols - format: "plot-v1, {access_token}"
    const protocolList = protocols.split(",").map((p) => p.trim());
    if (protocolList.length < 2 || protocolList[0] !== "plot-v1") {
      return new Response("Invalid protocol format", { status: 401 });
    }

    const access_token = protocolList[1];
    if (!access_token) {
      return new Response("Missing authentication token", { status: 401 });
    }

    // Validate the Clerk JWT locally (no network call)
    const logger = createLogger({
      durable_object: "Broadcast",
      operation: "handleWebSocket",
      ...(clientVersion ? { client_version: clientVersion } : {}),
      ...(clientPlatform ? { client_platform: clientPlatform } : {}),
    });

    try {
      const claims = await verifyToken(access_token, {
        jwtKey: atob(this.env.CLERK_JWT_KEY),
      });

      // Get the user's UUID from Clerk external_id (set during activation)
      const authenticatedUserId = (claims as any).external_id as
        | string
        | undefined;

      if (!authenticatedUserId) {
        return new Response("Authentication failed: missing user ID", {
          status: 401,
        });
      }

      // Validate that the authenticated user matches the userId in the path
      if (authenticatedUserId !== userIdFromPath) {
        return new Response("Unauthorized: User ID mismatch with path", {
          status: 403,
        });
      }

      // Set or validate the user ID for this Durable Object instance
      if (this.userId === null) {
        this.userId = authenticatedUserId;
      } else if (authenticatedUserId !== this.userId) {
        return new Response("Unauthorized: User ID mismatch with DO", {
          status: 403,
        });
      }
    } catch (error) {
      logger.error("Authentication error", error as Error, {
        user_id: userIdFromPath,
        client_id: clientId,
      });
      return new Response("Authentication failed", { status: 401 });
    }

    // Upgrade to WebSocket
    const webSocketPair = new WebSocketPair();
    const [client, server] = Object.values(webSocketPair);

    // Accept the WebSocket connection
    server.accept();

    // Defensive cleanup: if a connection already exists for this clientId,
    // close it before storing the new one. This handles edge cases where
    // the old connection wasn't properly cleaned up.
    const existingConnection = this.connections.get(clientId);
    if (existingConnection) {
      logger.info("Closing existing connection", { client_id: clientId });
      existingConnection.close(1000, "Replaced by new connection");
    }

    // Store the connection
    this.connections.set(clientId, server);

    // Notify UserSync DO that a client connected
    // This syncs the user_sync table so incremental updates work correctly
    try {
      const userSyncId = this.env.USER_SYNC.idFromName(this.userId);
      const userSync = this.env.USER_SYNC.get(userSyncId);
      await userSync.fetch(
        new Request("http://do/onClientConnected", {
          method: "POST",
          body: JSON.stringify({ userId: this.userId }),
        })
      );
    } catch (error) {
      logger.error("Error notifying UserSync of client connection", error as Error, {
        user_id: this.userId,
        client_id: clientId,
      });
      this.captureException(error as Error, { client_id: clientId });
      // Don't fail the connection if UserSync notification fails
    }

    // Handle WebSocket events
    server.addEventListener("close", () => {
      this.connections.delete(clientId);
      this.inactiveClients.delete(clientId);
      this.removeDeviceActivity(clientId);
    });

    server.addEventListener("error", () => {
      this.connections.delete(clientId);
      this.inactiveClients.delete(clientId);
      this.removeDeviceActivity(clientId);
    });

    server.addEventListener("message", (event) => {
      // Handle keepalive pings — support both plain string and structured JSON
      if (event.data === "ping") {
        server.send("pong");
        return;
      }
      try {
        const msg = JSON.parse(event.data as string) as Record<string, unknown>;
        if (msg.type === "ping") {
          server.send("pong");
          if (msg.active === true) {
            this.inactiveClients.delete(clientId);
            this.maybeRecordActivity(clientId);
          } else if (msg.active === false) {
            this.inactiveClients.add(clientId);
          }
          return;
        }
      } catch {
        // Not JSON — fall through to generic handler
      }
      logger.info("Received message from client", { client_id: clientId });
    });

    return new Response(null, {
      status: 101,
      webSocket: client,
      headers: {
        // Echo back the selected protocol (required by Chrome for strict WebSocket compliance)
        "Sec-WebSocket-Protocol": "plot-v1",
      },
    });
  }

  /**
   * Send a message to all connected clients except the specified client ID
   * Implements intelligent batching strategy
   */
  send(message: any, excludeClientId?: string): void {
    const now = Date.now();
    const queuedMessage: QueuedMessage = {
      message,
      clientId: excludeClientId,
      timestamp: now,
    };

    // Remove duplicate messages from queue
    this.messageQueue = this.messageQueue.filter(
      (queued) => JSON.stringify(queued.message) !== JSON.stringify(message)
    );

    this.messageQueue.push(queuedMessage);

    // Implement batching strategy
    if (this.lastMessageTime === 0 || now - this.lastMessageTime >= 1000) {
      // First message or more than 1 second since last message - send immediately
      this.flushMessages();
      this.lastMessageTime = now;
    } else {
      // Message arrived within 1 second - queue it
      if (this.batchTimeout !== null) {
        clearTimeout(this.batchTimeout);
      }

      // Set timeout to send after 1 second from the most recent message
      // But don't let it queue for more than 5 seconds total
      const timeUntilFlush = Math.min(
        1000,
        5000 - (now - this.lastMessageTime)
      );

      this.batchTimeout = setTimeout(() => {
        this.flushMessages();
        this.batchTimeout = null;
      }, timeUntilFlush);
    }
  }

  private flushMessages(): void {
    const logger = createLogger({
      durable_object: "Broadcast",
      operation: "flushMessages",
    });

    if (this.messageQueue.length === 0) {
      return;
    }

    // Group messages by client ID to exclude
    const messagesToSend = [...this.messageQueue];
    this.messageQueue = [];
    this.lastMessageTime = Date.now();

    // Send each message to appropriate clients
    for (const queuedMessage of messagesToSend) {
      const messageJson = JSON.stringify(queuedMessage.message);

      for (const [clientId, socket] of this.connections) {
        // Skip sending to the client that originated the message
        if (queuedMessage.clientId && clientId === queuedMessage.clientId) {
          continue;
        }

        try {
          if (socket.readyState === WebSocket.OPEN) {
            socket.send(messageJson);
          }
        } catch (error) {
          logger.error("Failed to send message to client", error as Error, {
            client_id: clientId,
          });
          // Remove the failed connection
          this.connections.delete(clientId);
        }
      }
    }
  }

  /**
   * Get the number of connected clients
   */
  getConnectionCount(): number {
    return this.connections.size;
  }

  /**
   * Check if there are any actively connected clients (not backgrounded).
   * Used by UserSync DO to decide between WebSocket sync and push notification.
   */
  hasConnectedClients(): boolean {
    // Only count clients that haven't sent active: false
    for (const clientId of this.connections.keys()) {
      if (!this.inactiveClients.has(clientId)) {
        return true;
      }
    }
    return false;
  }

  /**
   * Close all connections
   */
  closeAllConnections(): void {
    const logger = createLogger({
      durable_object: "Broadcast",
      operation: "closeAllConnections",
    });

    for (const [clientId, socket] of this.connections) {
      try {
        socket.close();
      } catch (error) {
        logger.error("Error closing connection for client", error as Error, {
          client_id: clientId,
        });
      }
    }
    this.connections.clear();
    this.inactiveClients.clear();
  }
}
