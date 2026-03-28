const PATH_CHARS =
  "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

/**
 * Generate a unique priority path.
 *
 * Generated in TypeScript instead of calling the database generate_path()
 * function because Hyperdrive caches SELECT results — concurrent requests
 * calling SELECT generate_path(parent => $1) with the same parent receive
 * the same cached random path, causing unique constraint violations.
 *
 * Matches the format of the database generate_path():
 * - With parent: 4 random alphanumeric chars appended (e.g. "parent.xYz1")
 * - Without parent: 12 random alphanumeric chars (e.g. "aBcDeFgHiJkL")
 */
export function generatePath(parent?: string | null): string {
  const len = parent ? 4 : 12;
  let random = "";
  for (let i = 0; i < len; i++) {
    random += PATH_CHARS[Math.floor(Math.random() * PATH_CHARS.length)];
  }
  return parent ? `${parent}.${random}` : random;
}
