/**
 * AES-256-GCM encryption/decryption using Web Crypto API.
 * Used for encrypting user-provided AI API keys at rest.
 */

/**
 * Import a hex-encoded 256-bit key for AES-GCM.
 */
async function importKey(hexKey: string): Promise<CryptoKey> {
  const keyBytes = new Uint8Array(
    hexKey.match(/.{2}/g)!.map((byte) => parseInt(byte, 16))
  );
  return crypto.subtle.importKey("raw", keyBytes, { name: "AES-GCM" }, false, [
    "encrypt",
    "decrypt",
  ]);
}

/**
 * Encrypt plaintext using AES-256-GCM.
 * @param plaintext - The string to encrypt
 * @param hexKey - 64-character hex string (256 bits)
 * @returns Base64-encoded ciphertext and IV
 */
export async function encrypt(
  plaintext: string,
  hexKey: string
): Promise<{ ciphertext: string; iv: string }> {
  const key = await importKey(hexKey);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const encoded = new TextEncoder().encode(plaintext);

  const encrypted = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv },
    key,
    encoded
  );

  return {
    ciphertext: btoa(String.fromCharCode(...new Uint8Array(encrypted))),
    iv: btoa(String.fromCharCode(...iv)),
  };
}

/**
 * Decrypt AES-256-GCM ciphertext.
 * @param ciphertext - Base64-encoded ciphertext
 * @param iv - Base64-encoded initialization vector
 * @param hexKey - 64-character hex string (256 bits)
 * @returns The original plaintext
 */
export async function decrypt(
  ciphertext: string,
  iv: string,
  hexKey: string
): Promise<string> {
  const key = await importKey(hexKey);
  const ivBytes = Uint8Array.from(atob(iv), (c) => c.charCodeAt(0));
  const ciphertextBytes = Uint8Array.from(atob(ciphertext), (c) =>
    c.charCodeAt(0)
  );

  const decrypted = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: ivBytes },
    key,
    ciphertextBytes
  );

  return new TextDecoder().decode(decrypted);
}
