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
}

const PUBSUB_SCOPE = "https://www.googleapis.com/auth/pubsub";

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

  const response = await fetch(url, {
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

  const response = await fetch(url, {
    method: "PUT",
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      topic: subscriptionConfig.topicName,
      pushConfig: {
        pushEndpoint: subscriptionConfig.pushEndpoint,
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

  const response = await fetch(url, {
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

  const response = await fetch(url, {
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
  const policyResponse = await fetch(url, {
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
  const setResponse = await fetch(setUrl, {
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
let googlePublicKeysCache: { keys: Record<string, string>; expires: number } | null = null;

/**
 * Fetches Google's public keys for JWT verification.
 * Caches the keys based on the Cache-Control header.
 */
async function getGooglePublicKeys(): Promise<Record<string, string>> {
  const now = Date.now();

  // Return cached keys if still valid
  if (googlePublicKeysCache && googlePublicKeysCache.expires > now) {
    return googlePublicKeysCache.keys;
  }

  const response = await fetch("https://www.googleapis.com/oauth2/v1/certs");

  if (!response.ok) {
    throw new Error(`Failed to fetch Google public keys: ${response.statusText}`);
  }

  const keys = await response.json() as Record<string, string>;

  // Parse cache-control header to determine cache duration
  const cacheControl = response.headers.get("cache-control");
  let maxAge = 3600; // Default 1 hour
  if (cacheControl) {
    const maxAgeMatch = cacheControl.match(/max-age=(\d+)/);
    if (maxAgeMatch) {
      maxAge = parseInt(maxAgeMatch[1], 10);
    }
  }

  googlePublicKeysCache = {
    keys,
    expires: now + maxAge * 1000,
  };

  return keys;
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

    // Get Google's public keys
    const publicKeys = await getGooglePublicKeys();
    const publicKeyPem = publicKeys[header.kid];

    if (!publicKeyPem) {
      logger.warn("Public key not found for kid", { kid: header.kid });
      return false;
    }

    // Import the public key
    const pemHeader = "-----BEGIN CERTIFICATE-----";
    const pemFooter = "-----END CERTIFICATE-----";
    const pemContents = publicKeyPem
      .replace(pemHeader, "")
      .replace(pemFooter, "")
      .replace(/\s/g, "");

    const binaryDer = Uint8Array.from(atob(pemContents), c => c.charCodeAt(0));

    const publicKey = await crypto.subtle.importKey(
      "spki",
      binaryDer,
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
