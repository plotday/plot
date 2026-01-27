/**
 * Normalize API URL to a filesystem-safe namespace identifier.
 *
 * Examples:
 *   https://api.plot.day → api.plot.day
 *   http://localhost:8787 → localhost-8787
 *   https://api.plot.day/ → api.plot.day (trailing slash removed)
 *   http://[::1]:8787 → ::1-8787 (IPv6 supported)
 *   https://api.plot.day/v2 → api.plot.day (path ignored)
 *
 * @throws {Error} If URL is malformed or invalid
 */
export function normalizeApiUrl(apiUrl: string): string {
  let url: URL;

  try {
    url = new URL(apiUrl);
  } catch (error) {
    throw new Error(`Invalid API URL: ${apiUrl}`);
  }

  // Reject non-http(s) protocols
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new Error(
      `Invalid API URL protocol: ${url.protocol} (must be http or https)`
    );
  }

  // Extract hostname (handles IPv6 by removing brackets)
  let hostname = url.hostname;

  // Get port
  const port = url.port;

  // Omit standard ports (80 for http, 443 for https)
  const isStandardPort =
    (url.protocol === "http:" && port === "80") ||
    (url.protocol === "https:" && port === "443") ||
    !port;

  if (isStandardPort) {
    return hostname;
  }

  // For non-standard ports, append with dash separator
  // (works for both IPv4/IPv6 since hostname has brackets removed)
  return `${hostname}-${port}`;
}
