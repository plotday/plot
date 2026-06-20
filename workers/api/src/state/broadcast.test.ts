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

// In-memory stand-in for the DO's `ctx.storage.sql`. Models the two activity
// tables faithfully so behavioural assertions (does last-active survive a
// disconnect? does others-active exclude the caller?) are meaningful rather
// than tautological. Recognises only the statements Broadcast actually runs.
function createSqlFake() {
  const device = new Map<string, number>();
  let user: number | null = null;
  return {
    device,
    exec(query: string, ...args: unknown[]): Array<Record<string, unknown>> {
      const q = query.replace(/\s+/g, " ").trim().toLowerCase();
      if (q.startsWith("create table")) return [];
      if (q.startsWith("insert or replace into device_activity")) {
        device.set(args[0] as string, args[1] as number);
        return [];
      }
      if (q.startsWith("insert into user_activity")) {
        const v = args[0] as number;
        user = user == null ? v : Math.max(user, v);
        return [];
      }
      if (q.startsWith("delete from device_activity where client_id")) {
        device.delete(args[0] as string);
        return [];
      }
      if (q.startsWith("select last_active_at from user_activity")) {
        return user == null ? [] : [{ last_active_at: user }];
      }
      if (q.startsWith("select client_id from device_activity")) {
        return [...device.keys()].map((client_id) => ({ client_id }));
      }
      if (q.includes("from device_activity where client_id !=")) {
        const exclude = args[0] as string;
        let max: number | null = null;
        for (const [c, t] of device) {
          if (c !== exclude) max = max == null ? t : Math.max(max, t);
        }
        return [{ max_active: max }];
      }
      if (q.includes("max(last_active_at) as max_active from device_activity")) {
        let max: number | null = null;
        for (const t of device.values()) max = max == null ? t : Math.max(max, t);
        return [{ max_active: max }];
      }
      throw new Error(`Unhandled SQL in fake: ${query}`);
    },
  };
}

function createBroadcast(): Broadcast {
  const sql = createSqlFake();
  return new Broadcast({ storage: { sql } } as any, {} as any);
}

async function getActive(b: Broadcast, path: string): Promise<string | null> {
  const res = await b.fetch(new Request(`http://do${path}`));
  const body = (await res.json()) as { lastActiveAt: string | null };
  return body.lastActiveAt;
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

describe("Broadcast activity tracking", () => {
  it("/last-active-persisted survives a device disconnect (email gating)", async () => {
    // Regression: closing the app used to wipe the user's activity record,
    // so the 18h email digest fired even though the user had opened Plot
    // earlier. The persisted timestamp must outlive the websocket.
    const b = createBroadcast();
    (b as any).maybeRecordActivity("c1");

    const before = await getActive(b, "/last-active-persisted");
    expect(before).not.toBeNull();

    (b as any).removeDeviceActivity("c1"); // device disconnects

    const after = await getActive(b, "/last-active-persisted");
    expect(after).toBe(before);
  });

  it("/last-active reflects only currently-connected devices (push gating)", async () => {
    // Push must keep its real-time semantics: once the user closes the app
    // ("walks away"), pushes should flow to their other devices.
    const b = createBroadcast();
    (b as any).maybeRecordActivity("c1");
    expect(await getActive(b, "/last-active")).not.toBeNull();

    (b as any).removeDeviceActivity("c1");
    expect(await getActive(b, "/last-active")).toBeNull();
  });

  it("/others-active excludes the caller and disconnected devices", async () => {
    const b = createBroadcast();
    addConnection(b, "c1");
    addConnection(b, "c2");
    (b as any).maybeRecordActivity("c1");
    (b as any).maybeRecordActivity("c2");

    // Another active, connected device → suppress this device's notification.
    expect(await getActive(b, "/others-active?excludeClient=c1")).not.toBeNull();

    // c2 disconnects → only the caller remains → nothing to suppress against.
    (b as any).connections.delete("c2");
    expect(await getActive(b, "/others-active?excludeClient=c1")).toBeNull();
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
