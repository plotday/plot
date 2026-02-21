/**
 * Shared GCP authentication utility.
 * Generates OAuth2 access tokens for Google Cloud APIs using service account credentials.
 */

/**
 * Generates a JWT token for Google service account authentication.
 * Uses RS256 signing algorithm with the service account's private key.
 */
async function generateJWT(
  serviceAccountEmail: string,
  serviceAccountKey: string,
  scope: string
): Promise<string> {
  const header = {
    alg: "RS256",
    typ: "JWT",
  };

  const now = Math.floor(Date.now() / 1000);
  const payload = {
    iss: serviceAccountEmail,
    scope,
    aud: "https://oauth2.googleapis.com/token",
    exp: now + 3600,
    iat: now,
  };

  const base64UrlEncode = (obj: object) => {
    const json = JSON.stringify(obj);
    const base64 = btoa(json);
    return base64.replace(/\+/g, "-").replace(/\//g, "_").replace(/=/g, "");
  };

  const encodedHeader = base64UrlEncode(header);
  const encodedPayload = base64UrlEncode(payload);
  const signatureInput = `${encodedHeader}.${encodedPayload}`;

  // Import the private key
  const pemKey = serviceAccountKey
    .replace(/\\n/g, "\n")
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s/g, "");

  const binaryKey = Uint8Array.from(atob(pemKey), (c) => c.charCodeAt(0));

  const cryptoKey = await crypto.subtle.importKey(
    "pkcs8",
    binaryKey,
    {
      name: "RSASSA-PKCS1-v1_5",
      hash: "SHA-256",
    },
    false,
    ["sign"]
  );

  // Sign the JWT
  const encoder = new TextEncoder();
  const signatureData = encoder.encode(signatureInput);
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    cryptoKey,
    signatureData
  );

  // Base64url encode signature
  const signatureArray = new Uint8Array(signature);
  const signatureBase64 = btoa(String.fromCharCode(...signatureArray));
  const encodedSignature = signatureBase64
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=/g, "");

  return `${signatureInput}.${encodedSignature}`;
}

/**
 * Exchanges a service account JWT for a GCP OAuth2 access token.
 *
 * @param serviceAccountEmail - The service account email
 * @param serviceAccountKey - The service account private key (PEM format)
 * @param scope - The OAuth2 scope to request
 * @returns The access token string
 */
export async function getGcpAccessToken(
  serviceAccountEmail: string,
  serviceAccountKey: string,
  scope: string
): Promise<string> {
  const jwt = await generateJWT(serviceAccountEmail, serviceAccountKey, scope);

  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }),
  });

  if (!response.ok) {
    const error = await response.text();
    throw new Error(`Failed to get GCP access token: ${error}`);
  }

  const data = (await response.json()) as { access_token: string };
  return data.access_token;
}
