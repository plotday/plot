#!/usr/bin/env tsx
/**
 * Idempotently register the three Unipile workspace webhooks for one env.
 *
 *   messaging       → new chat messages
 *   account_status  → account connected / disconnected / error / credentials
 *   users           → connection-request events (LinkedIn invitations)
 *
 * Run twice — once per env:
 *
 *   tsx scripts/bootstrap-unipile-webhooks.ts development https://api-kris.plot.day
 *   tsx scripts/bootstrap-unipile-webhooks.ts production
 *
 * Pulls UNIPILE_API_KEY, UNIPILE_DSN, UNIPILE_WEBHOOK_SECRET from
 * workers/api/.dev.vars.<env>. The webhook URL is built from the
 * 2nd positional arg if given (the dev tunnel URL is developer-
 * specific so it cannot live in .env), otherwise from API_ROOT in
 * the same file (the right shape for production).
 *
 * Existing webhooks pointing at our `${API_ROOT}/hook/messaging` URL
 * with the matching source are reused; the script never deletes.
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
import type { UnipileWebhookSource } from "../workers/api/src/twist/tools/unipile/types";

const SOURCES: UnipileWebhookSource[] = [
  "messaging",
  "account_status",
  "users",
];
const HEADER_NAME = "X-Plot-Webhook-Token";
const WEBHOOK_PATH = "/hook/messaging";

async function main(): Promise<void> {
  const envArg = process.argv[2];
  const urlArg = process.argv[3];
  if (envArg !== "development" && envArg !== "production") {
    fail(
      "Usage: bootstrap-unipile-webhooks.ts <development|production> [webhook-base-url]"
    );
  }

  const envFile = resolve(
    new URL("..", import.meta.url).pathname,
    `workers/api/.dev.vars.${envArg}`
  );
  const env = parseDotenv(readFileSync(envFile, "utf8"));

  const required = [
    "UNIPILE_API_KEY",
    "UNIPILE_DSN",
    "UNIPILE_WEBHOOK_SECRET",
  ] as const;
  for (const key of required) {
    if (!env[key]) fail(`Missing ${key} in ${envFile}`);
  }

  const baseUrl = urlArg ?? env.API_ROOT;
  if (!baseUrl) {
    fail(
      `No webhook base URL: pass one as the 2nd arg, or set API_ROOT in ${envFile}.`
    );
  }
  if (baseUrl.includes("localhost") || baseUrl.includes("127.0.0.1")) {
    fail(
      `Webhook URL looks local (${baseUrl}). Unipile cannot reach localhost.\n` +
        `Pass the cloudflared tunnel URL as the 2nd arg, e.g.\n` +
        `  pnpm bootstrap-unipile-webhooks ${envArg} https://api-kris.plot.day`
    );
  }
  const requestUrl = `${baseUrl.replace(/\/$/, "")}${WEBHOOK_PATH}`;

  const client = new UnipileClient({
    UNIPILE_API_KEY: env.UNIPILE_API_KEY!,
    UNIPILE_DSN: env.UNIPILE_DSN!,
    UNIPILE_WEBHOOK_SECRET: env.UNIPILE_WEBHOOK_SECRET!,
  });

  log(`Bootstrapping Unipile webhooks for ${envArg} (${requestUrl})`);

  const existing = (await client.listWebhooks()).items;
  for (const source of SOURCES) {
    const match = existing.find(
      (w) => w.source === source && w.request_url === requestUrl
    );
    const desiredHeader = {
      key: HEADER_NAME,
      value: env.UNIPILE_WEBHOOK_SECRET!,
    };
    const headerMatches = match?.headers?.some(
      (h) => h.key === HEADER_NAME && h.value === desiredHeader.value
    );

    if (match && headerMatches) {
      log(`  ${source}: already registered (${match.id}) — no change`);
      continue;
    }

    if (match) {
      log(
        `  ${source}: secret drifted on ${match.id}; deleting and recreating`
      );
      await client.deleteWebhook(match.id);
    }

    const created = await client.createWebhook({
      source,
      requestUrl,
      headers: [desiredHeader],
    });
    log(`  ${source}: created (${created.id})`);
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
