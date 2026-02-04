/**
 * Truncates a UUID v7 to create a 31-bit integer suitable for PostgreSQL's integer type.
 * Uses the random portion of the UUID (avoiding the timestamp) to ensure uniqueness.
 *
 * UUID v7 structure: aaaaaaaa-bbbb-7ccc-yyyy-eeeeeeeeeeee
 * - First 48 bits (aaaaaaaa-bbbb): Unix timestamp in milliseconds
 * - Next 4 bits (7): Version number
 * - Next 12 bits (ccc): More timestamp bits
 * - Next 2 bits (y): Variant bits
 * - Last 62 bits (yy-eeeeeeeeeeee): Random data for uniqueness
 *
 * This function extracts the last 64 bits and converts to a 31-bit integer.
 *
 * @param uuid - UUID v7 string in standard format (with or without hyphens)
 * @returns 31-bit integer derived from the random portion of the UUID
 * @throws Error if UUID format is invalid
 */
export function truncateUuidForUpdatedBy(uuid: string): number {
  if (!uuid || typeof uuid !== "string") {
    throw new Error("UUID must be a non-empty string");
  }

  // Remove hyphens and validate basic format
  const cleanUuid = uuid.replace(/-/g, "").toLowerCase();

  if (cleanUuid.length !== 32) {
    throw new Error(
      `Invalid UUID format: expected 32 hex characters, got ${cleanUuid.length}`
    );
  }

  // Validate hex characters
  if (!/^[0-9a-f]{32}$/.test(cleanUuid)) {
    throw new Error("UUID contains invalid characters: must be hexadecimal");
  }

  // Extract last 16 hex characters (64 bits) for uniqueness
  // This avoids the timestamp portion and uses the random data
  const last64Bits = cleanUuid.slice(-16);

  try {
    // Convert to BigInt to handle the full 64-bit value
    const bigIntValue = BigInt("0x" + last64Bits);

    // Convert to 31-bit signed integer (PostgreSQL integer range: -2^31 to 2^31-1)
    // We use modulo 2^31-1 and negate to produce negative values for twist writes.
    // Negative updated_by = twist/API origin, positive = app client origin.
    const maxValue = BigInt(2147483647); // 2^31 - 1
    const result = Number(bigIntValue % maxValue);

    // Always return negative for twists; avoid 0 (which means "default/unknown")
    return result === 0 ? -1 : -result;
  } catch (error) {
    throw new Error(
      `Failed to convert UUID to integer: ${
        error instanceof Error ? error.message : error
      }`
    );
  }
}

