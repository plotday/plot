#!/usr/bin/env tsx
/**
 * Idempotently register the single Unipile v2 webhook endpoint for one env.
 * v2 uses one endpoint per URL subscribing to many `trigger_events` (see
 * EVENTS below): new messages, account status, and new relations.
 *
 * Run twice — once per env:
 *
 *   tsx scripts/bootstrap-unipile-webhooks.ts development
 *   tsx scripts/bootstrap-unipile-webhooks.ts production
 *
 * The env arg selects which generated env file to source. The script
 * pulls UNIPILE_API_KEY, UNIPILE_WEBHOOK_SECRET, and API_ROOT from
 * workers/api/.dev.vars.<env>. (v2 uses a single host — no DSN.)
 *
 * v2 has ONE unified webhook endpoint per URL. An existing endpoint at our
 * `${API_ROOT}/hook/messaging` URL is deleted and recreated so the event list
 * and header stay current.
 * It does, however, refresh the X-Plot-Webhook-Token header on existing
 * webhooks by deleting-and-recreating when the stored secret differs
 * (Unipile has no PATCH for webhook headers).
 */

import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import {
  UnipileApiError,
  UnipileClient,
} from "../workers/api/src/twist/tools/unipile/client";

/**
 * v2 trigger events Plot subscribes to on the single unified webhook endpoint.
 * Every name here was validated against the live v2 API (creation rejects an
 * unknown index). v2 has no "invitation received" event — received invitations
 * are pulled via the invitations API, not pushed.
 */
const EVENTS = [
  "message.new",
  "account.add",
  "account.reconnect",
  "account.status.disconnected",
  "account.status.errored",
  "relation.new",
  "relation.request.accept",
];
const HEADER_NAME = "X-Plot-Webhook-Token";
const WEBHOOK_PATH = "/hook/messaging";
const WEBHOOK_NAME = "plot";

async function main(): Promise<void> {
  const envArg = process.argv[2];
  if (envArg !== "development" && envArg !== "production") {
    fail("Usage: bootstrap-unipile-webhooks.ts <development|production>");
  }

  const envFile = resolve(
    new URL("..", import.meta.url).pathname,
    `workers/api/.dev.vars.${envArg}`
  );
  const env = parseDotenv(readFileSync(envFile, "utf8"));

  const required = [
    "UNIPILE_API_KEY",
    "UNIPILE_WEBHOOK_SECRET",
    "API_ROOT",
  ] as const;
  for (const key of required) {
    if (!env[key]) fail(`Missing ${key} in ${envFile}`);
  }

  const apiRoot = env.API_ROOT!;
  if (apiRoot.includes("localhost") || apiRoot.includes("127.0.0.1")) {
    fail(
      `API_ROOT looks local (${apiRoot}). Unipile cannot reach localhost — use the tunnel URL or skip dev bootstrap.`
    );
  }
  const requestUrl = `${apiRoot.replace(/\/$/, "")}${WEBHOOK_PATH}`;

  const client = new UnipileClient({
    UNIPILE_API_KEY: env.UNIPILE_API_KEY!,
    UNIPILE_WEBHOOK_SECRET: env.UNIPILE_WEBHOOK_SECRET!,
  });

  log(`Bootstrapping Unipile v2 webhook for ${envArg} (${requestUrl})`);

  // v2 uses ONE unified endpoint per URL subscribing to all events. We also
  // attach our shared token as a delivery header; the endpoint additionally
  // returns its own signing `secret` (verification is finalized in live test).
  const existing = (await client.listWebhooks()).data;
  const match = existing.find((w) => w.url === requestUrl);
  if (match) {
    log(`  endpoint exists (${match.id}); recreating to refresh events/header`);
    await client.deleteWebhook(match.id);
  }
  const created = await client.createWebhook({
    name: WEBHOOK_NAME,
    url: requestUrl,
    triggerEvents: EVENTS,
    headers: [{ key: HEADER_NAME, value: env.UNIPILE_WEBHOOK_SECRET! }],
  });
  log(`  created (${created.id})`);
  if (created.secret) log(`  signing secret: ${created.secret}`);

  log("Done.");
}

function parseDotenv(text: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const line of text.split("\n")) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/);
    if (!m) continue;
    let val = m[2]!;
    if (
      (val.startsWith('"') && val.endsWith('"')) ||
      (val.startsWith("'") && val.endsWith("'"))
    ) {
      val = val.slice(1, -1);
    }
    out[m[1]!] = val;
  }
  return out;
}

function log(msg: string): void {
  process.stdout.write(msg + "\n");
}

function fail(msg: string): never {
  process.stderr.write(msg + "\n");
  process.exit(1);
}

main().catch((error: unknown) => {
  if (error instanceof UnipileApiError) {
    fail(`Unipile API error ${error.status}: ${error.message}\n${error.bodyText}`);
  }
  fail(String(error));
});
