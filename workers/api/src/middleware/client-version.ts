/**
 * Client version middleware for API worker.
 *
 * Parses the X-Plot-Client header sent by the Flutter app and attaches
 * structured client info to the Hono context. This enables version-gated
 * API behavior and observability (PostHog, logs).
 *
 * Header format: "1.5.2/42 (macOS)"
 * - version: semver string
 * - buildNumber: integer build number
 * - platform: macOS | Windows | Linux | iOS | Android | Web
 */

import type { MiddlewareHandler } from "hono";
import type { Bindings } from "../env";

export type ClientInfo = {
  version: string;
  buildNumber: number;
  platform: string;
  raw: string;
  apiVersion: number;
};

declare module "hono" {
  interface ContextVariableMap {
    clientInfo?: ClientInfo;
    apiVersion: number;
  }
}

const CLIENT_HEADER_RE = /^(\d+\.\d+\.\d+)\/(\d+)\s+\(([^)]+)\)$/;

/**
 * Parse the X-Plot-Client header value into structured ClientInfo.
 * Returns undefined if the header is missing or malformed.
 */
export function parseClientHeader(header: string | undefined): ClientInfo | undefined {
  if (!header) return undefined;
  const match = header.match(CLIENT_HEADER_RE);
  if (!match) return undefined;
  return {
    version: match[1],
    buildNumber: parseInt(match[2], 10),
    platform: match[3],
    raw: header,
    apiVersion: 0,
  };
}

/**
 * Compare two semver version strings.
 * Returns negative if a < b, 0 if equal, positive if a > b.
 */
export function compareVersions(a: string, b: string): number {
  const partsA = a.split(".").map(Number);
  const partsB = b.split(".").map(Number);
  for (let i = 0; i < 3; i++) {
    const diff = (partsA[i] ?? 0) - (partsB[i] ?? 0);
    if (diff !== 0) return diff;
  }
  return 0;
}

/**
 * Check if a client is at least the given minimum version.
 * Returns false if clientInfo is undefined (header not sent).
 */
export function isClientAtLeast(
  clientInfo: ClientInfo | undefined,
  minVersion: string
): boolean {
  if (!clientInfo) return false;
  return compareVersions(clientInfo.version, minVersion) >= 0;
}

/**
 * Client version middleware.
 *
 * - Parses X-Plot-Client header into structured ClientInfo
 * - Attaches to Hono context as c.var.clientInfo
 * - Never rejects requests missing the header (SDK clients, webhooks, etc.)
 */
export const clientVersionMiddleware: MiddlewareHandler<{ Bindings: Bindings }> = async (
  c,
  next
) => {
  const header = c.req.header("X-Plot-Client");
  const clientInfo = parseClientHeader(header);

  // Parse API version header (integer, default 0)
  const apiVersionHeader = c.req.header("X-Plot-API-Version");
  const apiVersion = apiVersionHeader ? parseInt(apiVersionHeader, 10) || 0 : 0;

  // Always set apiVersion on context so it's available even without X-Plot-Client
  c.set("apiVersion", apiVersion);

  if (clientInfo) {
    clientInfo.apiVersion = apiVersion;
    c.set("clientInfo", clientInfo);
  }
  await next();
};
