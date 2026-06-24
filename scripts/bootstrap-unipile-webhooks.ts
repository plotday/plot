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

  // UNIPILE_WEBHOOK_SECRET is NOT required to create the endpoint — v2 generates
  // the per-endpoint HMAC signing secret. We use it only to cross-check that the
  // stored secret matches the live endpoint.
  const required = ["UNIPILE_API_KEY", "API_ROOT"] as const;
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
    UNIPILE_WEBHOOK_SECRET: env.UNIPILE_WEBHOOK_SECRET ?? "",
  });

  log(`Bootstrapping Unipile v2 webhook for ${envArg} (${requestUrl})`);

  // v2 uses ONE unified endpoint per URL subscribing to all events, and signs
  // deliveries with an HMAC secret it GENERATES at creation. Recreating rotates
  // that secret, so we leave an existing endpoint in place and only create when
  // missing. The signing secret must be stored as UNIPILE_WEBHOOK_SECRET
  // (op://<env>/Unipile/v2/webhook secret) for hook-messaging to verify.
  const existing = (await client.listWebhooks()).data;
  const match = existing.find((w) => w.url === requestUrl);
  if (match) {
    log(`  endpoint exists (${match.id}) — left in place (recreating would rotate the signing secret).`);
    if (match.secret) {
      if (env.UNIPILE_WEBHOOK_SECRET && env.UNIPILE_WEBHOOK_SECRET === match.secret) {
        log(`  signing secret matches UNIPILE_WEBHOOK_SECRET ✓`);
      } else {
        log(`  ⚠️  UNIPILE_WEBHOOK_SECRET does NOT match the endpoint's signing secret.`);
        log(`     Update op://${envArg}/Unipile/v2/webhook secret to:`);
        log(`       ${match.secret}`);
      }
    }
    log(`  (To change the subscribed events, delete this endpoint in the dashboard and re-run — then update the stored secret.)`);
  } else {
    const created = await client.createWebhook({
      name: WEBHOOK_NAME,
      url: requestUrl,
      triggerEvents: EVENTS,
    });
    log(`  created (${created.id})`);
    log(`  ⚠️  STORE this signing secret as UNIPILE_WEBHOOK_SECRET (op://${envArg}/Unipile/v2/webhook secret):`);
    log(`       ${created.secret ?? "(none returned — check the dashboard)"}`);
  }

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
