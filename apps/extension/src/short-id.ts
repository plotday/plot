const BASE58_ALPHABET =
  "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

// Mirrors workers/api/src/state/email-notify.ts uuidToBase58 and the Dart
// Uuid.toShortString — keep them in sync so the URL works in any client.
export function uuidToBase58(uuid: string): string {
  const hex = uuid.replace(/-/g, "").toUpperCase();
  let num = BigInt("0x" + hex);
  if (num === 0n) return BASE58_ALPHABET[0];
  let result = "";
  const base = BigInt(58);
  while (num > 0n) {
    result = BASE58_ALPHABET[Number(num % base)] + result;
    num = num / base;
  }
  return result;
}
