/**
 * Google Cloud Pub/Sub client utility for managing topics and subscriptions.
 *
 * This utility handles the creation and deletion of Pub/Sub topics and push subscriptions
 * for Gmail webhook support. Each webhook gets its own dedicated topic and subscription.
 */

import { createLogger } from "@plotday/worker-util";
import { getGcpAccessToken } from "./gcp-auth";

interface PubSubConfig {
  projectId: string;
  serviceAccountEmail: string;
  serviceAccountKey: string;
}

interface PushSubscriptionConfig {
  topicName: string;
  subscriptionName: string;
  pushEndpoint: string;
  oidcServiceAccountEmail?: string;
  audience?: string;
}

const PUBSUB_SCOPE = "https://www.googleapis.com/auth/pubsub";

// The Pub/Sub control plane occasionally returns a transient 5xx (and rarely a
// 429) on topic/subscription mutations — pubsub.googleapis.com answered a bare
// `error code: 500` on topic creation, which propagated up through the Gmail
// connector as "Failed to create Gmail webhook: ..." and was captured as a
// PostHog exception (issue 019ed581) even though the next attempt would have
// succeeded. These blips self-resolve within seconds, so retry a small,
// bounded number of times with backoff before surfacing the failure. Non-
// transient responses (4xx, including 409 ALREADY_EXISTS) are returned
// immediately for the caller to handle — retrying them would only delay a
// permanent outcome.
const PUBSUB_RETRY_ATTEMPTS = 3; // 1 initial attempt + 2 retries
const PUBSUB_RETRY_BASE_DELAY_MS = 250;

function isTransientPubSubStatus(status: number): boolean {
  return status >= 500 || status === 429;
}

/**
 * `fetch` wrapper that retries transient Pub/Sub API failures (HTTP 5xx / 429
 * and network-level throws) with exponential backoff. On a non-transient
 * response, or once retries are exhausted, the (possibly still-failing)
 * Response is returned so the caller's existing `!response.ok` handling reports
 * the original error message unchanged.
 */
async function pubsubFetch(url: string, init: RequestInit): Promise<Response> {
  let lastError: unknown;
  for (let attempt = 0; attempt < PUBSUB_RETRY_ATTEMPTS; attempt++) {
    const isLastAttempt = attempt === PUBSUB_RETRY_ATTEMPTS - 1;
    try {
      const response = await fetch(url, init);
      if (!isTransientPubSubStatus(response.status) || isLastAttempt) {
        return response;
      }
    } catch (error) {
      // Network-level failure (connection lost, DNS) — retry like a 5xx.
      lastError = error;
      if (isLastAttempt) throw error;
    }
    await new Promise((resolve) =>
      setTimeout(resolve, PUBSUB_RETRY_BASE_DELAY_MS * 2 ** attempt)
    );
  }
  // Unreachable: the final iteration always returns or throws. Present only to
  // satisfy the type checker.
  throw lastError instanceof Error
    ? lastError
    : new Error("pubsubFetch: retries exhausted");
}

/**
 * Gets an access token for Pub/Sub API calls.
 */
async function getAccessToken(
  serviceAccountEmail: string,
  serviceAccountKey: string
): Promise<string> {
  return getGcpAccessToken(serviceAccountEmail, serviceAccountKey, PUBSUB_SCOPE);
}

/**
 * Creates a Pub/Sub topic.
 *
 * @param config - Pub/Sub configuration
 * @param topicId - Unique topic ID (e.g., "gmail-webhook-abc123")
 * @returns Full topic name (e.g., "projects/plot-prod/topics/gmail-webhook-abc123")
 */
export async function createTopic(
  config: PubSubConfig,
  topicId: string
): Promise<string> {
  const accessToken = await getAccessToken(
    config.serviceAccountEmail,
    config.serviceAccountKey
  );

  const topicName = `projects/${config.projectId}/topics/${topicId}`;
  const url = `https://pubsub.googleapis.com/v1/${topicName}`;

  const response = await pubsubFetch(url, {
    method: "PUT",
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({}),
  });

  if (!response.ok) {
    const error = await response.text();
    throw new Error(`Failed to create Pub/Sub topic: ${error}`);
  }

  return topicName;
}

/**
 * Creates a push subscription for a topic.
 *
 * @param config - Pub/Sub configuration
 * @param subscriptionConfig - Subscription configuration
 */
export async function createPushSubscription(
  config: PubSubConfig,
  subscriptionConfig: PushSubscriptionConfig
): Promise<void> {
  const accessToken = await getAccessToken(
    config.serviceAccountEmail,
    config.serviceAccountKey
  );

  const subscriptionName = `projects/${config.projectId}/subscriptions/${subscriptionConfig.subscriptionName}`;
  const url = `https://pubsub.googleapis.com/v1/${subscriptionName}`;

  const response = await pubsubFetch(url, {
    method: "PUT",
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      topic: subscriptionConfig.topicName,
      pushConfig: {
        pushEndpoint: subscriptionConfig.pushEndpoint,
        ...(subscriptionConfig.oidcServiceAccountEmail
          ? {
              oidcToken: {
                serviceAccountEmail: subscriptionConfig.oidcServiceAccountEmail,
                audience: subscriptionConfig.audience ?? subscriptionConfig.pushEndpoint,
              },
            }
          : {}),
      },
      ackDeadlineSeconds: 10,
    }),
  });

  if (!response.ok) {
    const error = await response.text();
    throw new Error(`Failed to create push subscription: ${error}`);
  }
}

/**
 * Deletes a Pub/Sub topic.
 *
 * @param config - Pub/Sub configuration
 * @param topicName - Full topic name (e.g., "projects/plot-prod/topics/gmail-webhook-abc123")
 */
export async function deleteTopic(
  config: PubSubConfig,
  topicName: string
): Promise<void> {
  const accessToken = await getAccessToken(
    config.serviceAccountEmail,
    config.serviceAccountKey
  );

  const url = `https://pubsub.googleapis.com/v1/${topicName}`;

  const response = await pubsubFetch(url, {
    method: "DELETE",
    headers: {
      Authorization: `Bearer ${accessToken}`,
    },
  });

  if (!response.ok) {
    const error = await response.text();
    throw new Error(`Failed to delete Pub/Sub topic: ${error}`);
  }
}

/**
 * Deletes a push subscription.
 *
 * @param config - Pub/Sub configuration
 * @param subscriptionName - Full subscription name (e.g., "projects/plot-prod/subscriptions/gmail-webhook-abc123")
 */
export async function deleteSubscription(
  config: PubSubConfig,
  subscriptionName: string
): Promise<void> {
  const accessToken = await getAccessToken(
    config.serviceAccountEmail,
    config.serviceAccountKey
  );

  const url = `https://pubsub.googleapis.com/v1/${subscriptionName}`;

  const response = await pubsubFetch(url, {
    method: "DELETE",
    headers: {
      Authorization: `Bearer ${accessToken}`,
    },
  });

  if (!response.ok) {
    const error = await response.text();
    throw new Error(`Failed to delete push subscription: ${error}`);
  }
}

/**
 * Grants a service account the `roles/pubsub.publisher` role on a topic.
 *
 * Required for services like Google Workspace Events that need to publish
 * to the topic but don't automatically grant themselves access (unlike Gmail's
 * `users.watch()` which handles this internally).
 *
 * @param config - Pub/Sub configuration
 * @param topicName - Full topic name (e.g., "projects/plot-core/topics/ps-abc123")
 * @param serviceAccount - Service account email to grant publish access
 */
export async function grantTopicPublisher(
  config: PubSubConfig,
  topicName: string,
  serviceAccount: string
): Promise<void> {
  const accessToken = await getAccessToken(
    config.serviceAccountEmail,
    config.serviceAccountKey
  );

  const url = `https://pubsub.googleapis.com/v1/${topicName}:getIamPolicy`;
  const policyResponse = await pubsubFetch(url, {
    method: "GET",
    headers: { Authorization: `Bearer ${accessToken}` },
  });

  let policy: { bindings?: Array<{ role: string; members: string[] }>; etag?: string } = {};
  if (policyResponse.ok) {
    policy = await policyResponse.json() as typeof policy;
  }

  const member = serviceAccount.startsWith("serviceAccount:")
    ? serviceAccount
    : `serviceAccount:${serviceAccount}`;

  // Check if binding already exists
  const bindings = policy.bindings ?? [];
  const publisherBinding = bindings.find(
    (b) => b.role === "roles/pubsub.publisher"
  );
  if (publisherBinding?.members.includes(member)) {
    return; // Already granted
  }

  // Add publisher binding
  if (publisherBinding) {
    publisherBinding.members.push(member);
  } else {
    bindings.push({ role: "roles/pubsub.publisher", members: [member] });
  }

  const setUrl = `https://pubsub.googleapis.com/v1/${topicName}:setIamPolicy`;
  const setResponse = await pubsubFetch(setUrl, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      policy: { bindings, etag: policy.etag },
    }),
  });

  if (!setResponse.ok) {
    const error = await setResponse.text();
    throw new Error(`Failed to grant publisher on topic: ${error}`);
  }
}

/**
 * Generates a unique topic ID for a Gmail webhook.
 */
export function generateTopicId(): string {
  return `gmail-webhook-${crypto.randomUUID()}`;
}

/**
 * Google's public keys cache (refreshed periodically)
 */
type JwkKey = { kid: string; kty: string; alg: string; use: string; n: string; e: string };
let googleJwkCache: { keys: JwkKey[]; expires: number } | null = null;

/**
 * Fetches Google's public keys as JWKs for JWT verification.
 * Uses the v3 endpoint which returns JWK format (easier to import than X.509 certs).
 * Caches the keys based on the Cache-Control header.
 */
async function getGoogleJwks(): Promise<JwkKey[]> {
  const now = Date.now();

  if (googleJwkCache && googleJwkCache.expires > now) {
    return googleJwkCache.keys;
  }

  const response = await fetch("https://www.googleapis.com/oauth2/v3/certs");

  if (!response.ok) {
    throw new Error(`Failed to fetch Google public keys: ${response.statusText}`);
  }

  const data = await response.json() as { keys: JwkKey[] };

  const cacheControl = response.headers.get("cache-control");
  let maxAge = 3600;
  if (cacheControl) {
    const maxAgeMatch = cacheControl.match(/max-age=(\d+)/);
    if (maxAgeMatch) {
      maxAge = parseInt(maxAgeMatch[1], 10);
    }
  }

  googleJwkCache = {
    keys: data.keys,
    expires: now + maxAge * 1000,
  };

  return data.keys;
}

/**
 * Decodes a base64url string to UTF-8.
 */
function base64UrlDecode(str: string): string {
  // Convert base64url to base64
  const base64 = str.replace(/-/g, "+").replace(/_/g, "/");
  // Pad with = if needed
  const padded = base64 + "==".substring(0, (4 - (base64.length % 4)) % 4);
  // Decode from base64
  const decoded = atob(padded);
  return decoded;
}

/**
 * Verifies a Google Pub/Sub JWT token.
 * Returns true if the token is valid, false otherwise.
 *
 * @param authHeader - The Authorization header value (format: "Bearer <token>")
 * @param projectId - The Google Cloud project ID (used to validate audience)
 *
 * Reference: https://cloud.google.com/pubsub/docs/push#verify_push_requests
 */
export async function verifyPubSubToken(
  authHeader: string | undefined,
  projectId: string
): Promise<boolean> {
  const logger = createLogger({
    operation: "verifyPubSubToken",
  });

  if (!authHeader) {
    return false;
  }

  // Extract the token from "Bearer <token>"
  const bearerPrefix = "Bearer ";
  if (!authHeader.startsWith(bearerPrefix)) {
    return false;
  }

  const token = authHeader.substring(bearerPrefix.length);

  try {
    // Split JWT into parts
    const parts = token.split(".");
    if (parts.length !== 3) {
      return false;
    }

    const [headerB64, payloadB64, signatureB64] = parts;

    // Decode header and payload
    const headerJson = base64UrlDecode(headerB64);
    const payloadJson = base64UrlDecode(payloadB64);

    const header = JSON.parse(headerJson) as { alg: string; kid: string };
    const payload = JSON.parse(payloadJson) as {
      iss: string;
      aud: string;
      exp: number;
      iat: number;
      email?: string;
      email_verified?: boolean;
    };

    // Verify algorithm
    if (header.alg !== "RS256") {
      logger.warn("Invalid JWT algorithm", { algorithm: header.alg });
      return false;
    }

    // Verify issuer
    const validIssuers = ["accounts.google.com", "https://accounts.google.com"];
    if (!validIssuers.includes(payload.iss)) {
      logger.warn("Invalid JWT issuer", { issuer: payload.iss });
      return false;
    }

    // Verify expiration
    const now = Math.floor(Date.now() / 1000);
    if (payload.exp < now) {
      logger.warn("JWT expired", { exp: payload.exp, now });
      return false;
    }

    // Verify issued-at time is not in the future (with 60s tolerance for clock skew)
    if (payload.iat > now + 60) {
      logger.warn("JWT issued in the future", { iat: payload.iat, now });
      return false;
    }

    // Verify audience matches the project
    // Audience can be the full push endpoint URL or just the project number/ID
    // For simplicity, we just check if it contains the project ID
    if (!payload.aud.includes(projectId)) {
      logger.warn("JWT audience mismatch", {
        audience: payload.aud,
        project_id: projectId,
      });
      return false;
    }

    // Get Google's public keys (JWK format)
    const jwks = await getGoogleJwks();
    const jwk = jwks.find(k => k.kid === header.kid);

    if (!jwk) {
      logger.warn("Public key not found for kid", { kid: header.kid });
      return false;
    }

    const publicKey = await crypto.subtle.importKey(
      "jwk",
      jwk,
      {
        name: "RSASSA-PKCS1-v1_5",
        hash: "SHA-256",
      },
      false,
      ["verify"]
    );

    // Verify signature
    const encoder = new TextEncoder();
    const data = encoder.encode(`${headerB64}.${payloadB64}`);

    // Decode signature from base64url
    const signatureBase64 = signatureB64.replace(/-/g, "+").replace(/_/g, "/");
    const signaturePadded = signatureBase64 + "==".substring(0, (4 - (signatureBase64.length % 4)) % 4);
    const signatureBytes = Uint8Array.from(atob(signaturePadded), c => c.charCodeAt(0));

    const isValid = await crypto.subtle.verify(
      "RSASSA-PKCS1-v1_5",
      publicKey,
      signatureBytes,
      data
    );

    if (!isValid) {
      logger.warn("JWT signature verification failed");
    }

    return isValid;
  } catch (error) {
    logger.error("Error verifying Pub/Sub token", error as Error);
    return false;
  }
}
