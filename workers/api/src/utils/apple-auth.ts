// Apple Sign in with Apple — server-side token revocation.
//
// Required for App Store guideline 5.1.1(v) compliance: when a user who
// signed in via Apple deletes their account, we must call Apple's
// /auth/revoke endpoint so the app stops appearing under their Apple ID's
// "Apps Using Apple ID" list. Clerk does not do this automatically on
// users.deleteUser() / users.banUser().
//
// Spec: https://developer.apple.com/documentation/signinwithapplerestapi/revoke-tokens

interface AppleAuthEnv {
  AUTH_APPLE_TEAM_ID: string;
  AUTH_APPLE_KEY_ID: string;
  AUTH_APPLE_PRIVATE_KEY: string;
}

/** Apple client IDs configured for Plot's two Sign in with Apple flows. */
export interface AppleClientIds {
  /** Native iOS bundle ID — issued tokens via the native SDK on iOS. */
  native: string;
  /** Web Services ID — issued tokens via the web OAuth flow. */
  web: string;
}

function base64UrlEncode(input: ArrayBuffer | Uint8Array | string): string {
  let bytes: Uint8Array;
  if (typeof input === "string") {
    bytes = new TextEncoder().encode(input);
  } else if (input instanceof ArrayBuffer) {
    bytes = new Uint8Array(input);
  } else {
    bytes = input;
  }
  let str = "";
  for (const b of bytes) str += String.fromCharCode(b);
  return btoa(str).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function importApplePrivateKey(pem: string): Promise<CryptoKey> {
  // Allow either real newlines or escaped "\n" (matching how other PEM
  // secrets like GCP_SERVICE_ACCOUNT_KEY are stored in .dev.vars).
  const normalized = pem.replace(/\\n/g, "\n");
  if (!normalized.includes("-----END PRIVATE KEY-----")) {
    // Most likely cause: a multi-line .p8 was written to .dev.vars without
    // quoting, so dotenv only captured the BEGIN header. Fix by storing the
    // key as a single line with literal "\n" escapes (matching GCP key),
    // or push it as a wrangler secret in production.
    throw new Error(
      "AUTH_APPLE_PRIVATE_KEY is truncated — value must contain BEGIN…END PRIVATE KEY block"
    );
  }
  const base64 = normalized
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s/g, "");
  const binary = atob(base64);
  const der = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) der[i] = binary.charCodeAt(i);
  return crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"]
  );
}

/** Builds a client_secret JWT (ES256) per Apple's SIWA spec. */
async function generateAppleClientSecret(
  env: AppleAuthEnv,
  clientId: string
): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "ES256", kid: env.AUTH_APPLE_KEY_ID, typ: "JWT" };
  const payload = {
    iss: env.AUTH_APPLE_TEAM_ID,
    iat: now,
    exp: now + 300,
    aud: "https://appleid.apple.com",
    sub: clientId,
  };
  const data = `${base64UrlEncode(JSON.stringify(header))}.${base64UrlEncode(
    JSON.stringify(payload)
  )}`;
  const key = await importApplePrivateKey(env.AUTH_APPLE_PRIVATE_KEY);
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(data)
  );
  return `${data}.${base64UrlEncode(signature)}`;
}

/**
 * Revokes a Sign in with Apple token for the given client. Apple verifies
 * that the token was issued for the supplied client_id, so callers that
 * don't know which flow (native vs web) issued the token should try both
 * via {@link revokeAppleTokenForAnyClient}.
 */
async function revokeAppleToken(
  token: string,
  clientId: string,
  env: AppleAuthEnv
): Promise<void> {
  const clientSecret = await generateAppleClientSecret(env, clientId);
  const body = new URLSearchParams({
    client_id: clientId,
    client_secret: clientSecret,
    token,
    token_type_hint: "access_token",
  });
  const response = await fetch("https://appleid.apple.com/auth/revoke", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: body.toString(),
  });
  if (!response.ok) {
    const text = await response.text();
    throw new Error(
      `Apple /auth/revoke failed (client_id=${clientId}): ${response.status} ${text}`
    );
  }
}

/**
 * Tries to revoke the Apple token under each configured client ID until one
 * succeeds. Apple binds tokens to the client they were issued for, and we
 * can't tell from the token alone whether the user signed in natively on
 * iOS (client_id = bundle ID) or via the web flow (client_id = Services ID).
 *
 * Returns the client ID that worked, or throws if all attempts failed.
 */
export async function revokeAppleTokenForAnyClient(
  token: string,
  clientIds: AppleClientIds,
  env: AppleAuthEnv
): Promise<string> {
  const errors: string[] = [];
  for (const clientId of [clientIds.native, clientIds.web]) {
    try {
      await revokeAppleToken(token, clientId, env);
      return clientId;
    } catch (e) {
      errors.push(e instanceof Error ? e.message : String(e));
    }
  }
  throw new Error(
    `Apple /auth/revoke failed for all configured client IDs: ${errors.join(" | ")}`
  );
}
