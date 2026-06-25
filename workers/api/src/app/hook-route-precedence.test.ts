/**
 * Regression guard for the `/hook/*` route-precedence bug.
 *
 * `Network.PATH` registers a catch-all `webhook.all("/hook/:token", …)` that
 * enqueues a WebhookMessage keyed on the path segment as a callback token. The
 * specific provider webhooks `/hook/messaging` (Unipile) and `/hook/todoist`
 * live in their own Hono apps mounted alongside it.
 *
 * Hono runs every matching handler in REGISTRATION ORDER and stops at the first
 * one that returns a response. So if the catch-all is registered before the
 * specific app, `POST /hook/messaging` is hijacked: the catch-all enqueues
 * `token="messaging"` (which later fails INVALID_TOKEN_FORMAT in the queue
 * consumer and is dropped) and the real messaging handler never runs.
 *
 * Two layers of protection here:
 *   1. A behavioural test proving WHY order matters (real apps vs. a faithful
 *      replica of the catch-all from webhook.ts).
 *   2. A source-order assertion on index.ts — the only way to guard the literal
 *      mount order, since the real `webhook`/`index` modules don't import
 *      cleanly in the unit (node) config.
 */

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { Hono } from "hono";
import { describe, it, expect, vi } from "vitest";

import hookMessaging from "./hook-messaging";
import hookTodoist from "./hook-todoist";

/**
 * Faithful stand-in for the two catch-all routes in webhook.ts
 * (`webhook.all(Network.PATH, …)` and `/hook-async/:token`). It records the
 * token it would enqueue and returns the same `{ queued: true }` shape, so a
 * hijack is observable without importing the heavy real `webhook` app.
 */
function catchAllApp(onEnqueue: (token: string) => void) {
  const app = new Hono();
  const handler = (c: any) => {
    onEnqueue(c.req.param("token"));
    return c.json({ queued: true });
  };
  app.all("/hook/:token", handler);
  app.all("/hook-async/:token", handler);
  return app;
}

describe("/hook/* route precedence", () => {
  it("routes /hook/messaging to its real handler when mounted before the catch-all", async () => {
    const enqueue = vi.fn();
    const app = new Hono();
    // Production-correct order: specific apps first, catch-all last.
    app.route("/", hookMessaging);
    app.route("/", hookTodoist);
    app.route("/", catchAllApp(enqueue));

    const res = await app.request(
      "/hook/messaging",
      { method: "POST", body: "{}" },
      {},
    );

    // Reached the messaging handler: missing signature → 401, NOT enqueued.
    expect(res.status).toBe(401);
    expect(enqueue).not.toHaveBeenCalled();
  });

  it("routes /hook/todoist to its real handler when mounted before the catch-all", async () => {
    const enqueue = vi.fn();
    const app = new Hono();
    app.route("/", hookMessaging);
    app.route("/", hookTodoist);
    app.route("/", catchAllApp(enqueue));

    const res = await app.request(
      "/hook/todoist",
      { method: "POST", body: "{}" },
      {},
    );

    expect(res.status).toBe(401);
    expect(enqueue).not.toHaveBeenCalled();
  });

  it("still serves genuine callback tokens through the catch-all", async () => {
    const enqueue = vi.fn();
    const app = new Hono();
    app.route("/", hookMessaging);
    app.route("/", hookTodoist);
    app.route("/", catchAllApp(enqueue));

    const token = "a".repeat(64) + ":secret";
    const res = await app.request(
      `/hook/${token}`,
      { method: "POST", body: "{}" },
      {},
    );

    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ queued: true });
    expect(enqueue).toHaveBeenCalledWith(token);
  });

  it("DEMONSTRATES the bug: catch-all first hijacks /hook/messaging", async () => {
    const enqueue = vi.fn();
    const app = new Hono();
    // Broken order — what index.ts did before the fix (webhook mounted first).
    app.route("/", catchAllApp(enqueue));
    app.route("/", hookMessaging);
    app.route("/", hookTodoist);

    const res = await app.request(
      "/hook/messaging",
      { method: "POST", body: "{}" },
      {},
    );

    // Hijacked: the catch-all enqueued the path segment as a bogus token.
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ queued: true });
    expect(enqueue).toHaveBeenCalledWith("messaging");
  });

  it("index.ts mounts the catch-all `webhook` app AFTER the specific /hook apps", () => {
    const indexSrc = readFileSync(
      fileURLToPath(new URL("../index.ts", import.meta.url)),
      "utf8",
    );
    const idx = (needle: string) => {
      const i = indexSrc.indexOf(needle);
      expect(i, `expected to find \`${needle}\` in index.ts`).toBeGreaterThan(-1);
      return i;
    };
    const webhookMount = idx('app.route("/", webhook)');
    const messagingMount = idx('app.route("/", hookMessaging)');
    const todoistMount = idx('app.route("/", hookTodoist)');

    // The `webhook` app owns the `/hook/:token` catch-all, so it MUST be
    // registered after every specific `/hook/<name>` app or it shadows them.
    expect(webhookMount).toBeGreaterThan(messagingMount);
    expect(webhookMount).toBeGreaterThan(todoistMount);
  });
});
