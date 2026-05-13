import { describe, expect, it } from "vitest";

import { Broadcast } from "./broadcast";

// Minimal stand-in for a connected WebSocket. We only exercise the fields
// `flushMessages` touches: `readyState` (must equal WebSocket.OPEN === 1) and
// `send()`.
class FakeWebSocket {
  readonly readyState = 1;
  readonly sent: string[] = [];
  send(data: string): void {
    this.sent.push(data);
  }
}

function createBroadcast(): Broadcast {
  return new Broadcast({} as any, {} as any);
}

function addConnection(b: Broadcast, clientId: string): FakeWebSocket {
  const ws = new FakeWebSocket();
  (b as any).connections.set(clientId, ws);
  return ws;
}

function markInactive(b: Broadcast, clientId: string): void {
  (b as any).inactiveClients.add(clientId);
}

describe("Broadcast.send", () => {
  it("delivers to a connected client", () => {
    const b = createBroadcast();
    const ws = addConnection(b, "c1");

    b.send({ type: "sync", tables: ["thread"] });

    expect(ws.sent).toEqual([
      JSON.stringify({ type: "sync", tables: ["thread"] }),
    ]);
  });

  it("delivers to a backgrounded client (active:false) with an open socket", () => {
    // Inactive ≠ disconnected. `{active: false}` exists so other devices
    // still receive FCM while a desktop app is backgrounded — it must NOT
    // suppress WebSocket delivery to that desktop app. Regressing this
    // would resurrect the "calendar event doesn't appear until reload" bug.
    const b = createBroadcast();
    const ws = addConnection(b, "c1");
    markInactive(b, "c1");

    b.send({ type: "sync", tables: ["thread"] });

    expect(ws.sent).toEqual([
      JSON.stringify({ type: "sync", tables: ["thread"] }),
    ]);
  });

  it("excludes the originating client when excludeClientId is set", () => {
    const b = createBroadcast();
    const ws1 = addConnection(b, "c1");
    const ws2 = addConnection(b, "c2");

    b.send({ type: "sync" }, "c1");

    expect(ws1.sent).toEqual([]);
    expect(ws2.sent.length).toBe(1);
  });
});

describe("Broadcast.hasConnectedClients", () => {
  it("returns false when no clients are connected", () => {
    const b = createBroadcast();

    expect(b.hasConnectedClients()).toBe(false);
  });

  it("returns true when at least one client is not marked inactive", () => {
    const b = createBroadcast();
    addConnection(b, "active");
    addConnection(b, "background");
    markInactive(b, "background");

    expect(b.hasConnectedClients()).toBe(true);
  });

  it("returns false when every connected client is marked inactive", () => {
    // This is the FCM-routing signal: when every device is backgrounded,
    // PushNotify should still fire FCM to wake them. It is NOT a WebSocket
    // delivery gate — see the `Broadcast.send` test above.
    const b = createBroadcast();
    addConnection(b, "c1");
    addConnection(b, "c2");
    markInactive(b, "c1");
    markInactive(b, "c2");

    expect(b.hasConnectedClients()).toBe(false);
  });
});
