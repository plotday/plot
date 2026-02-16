import { DurableObject } from "cloudflare:workers";

import type { Bindings } from "../env";
import { createLogger } from "@plotday/worker-util";
import { disposeRpc } from "../utils/rpc";
import { verifyToken } from "@clerk/backend";

interface QueuedMessage {
  message: any;
  clientId?: string;
  timestamp: number;
}

export class Broadcast extends DurableObject<Bindings> {
  private connections: Map<string, WebSocket> = new Map();
  private messageQueue: QueuedMessage[] = [];
  private lastMessageTime: number = 0;
  private batchTimeout: ReturnType<typeof setTimeout> | null = null;
  private userId: string | null = null;

  constructor(ctx: DurableObjectState, env: Bindings) {
    super(ctx, env);
    // User ID will be set during first authentication
  }

  async fetch(request: Request): Promise<Response> {
    if (request.headers.get("Upgrade") === "websocket") {
      return this.handleWebSocket(request);
    }

    const url = new URL(request.url);
    if (url.pathname === "/hasConnectedClients" && request.method === "GET") {
      return Response.json({ hasConnectedClients: this.hasConnectedClients() });
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
        jwtKey: this.env.CLERK_JWT_KEY,
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
      const result = await userSync.fetch(
        new Request("http://do/onClientConnected", {
          method: "POST",
          body: JSON.stringify({ userId: this.userId }),
        })
      );
      disposeRpc(result);
    } catch (error) {
      logger.error("Error notifying UserSync of client connection", error as Error, {
        user_id: this.userId,
        client_id: clientId,
      });
      // Don't fail the connection if UserSync notification fails
    }

    // Handle WebSocket events
    server.addEventListener("close", () => {
      this.connections.delete(clientId);
    });

    server.addEventListener("error", () => {
      this.connections.delete(clientId);
    });

    server.addEventListener("message", (event) => {
      // Respond to keepalive pings silently
      if (event.data === "ping") {
        server.send("pong");
        return;
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
   * Check if there are any connected clients
   * Used by UserSync DO to skip sync when no clients are connected
   */
  hasConnectedClients(): boolean {
    return this.connections.size > 0;
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
  }
}
