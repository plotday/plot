import { WorkerEntrypoint } from "cloudflare:workers";

/**
 * HttpProxy acts as an outbound filter for agent workers, controlling which
 * URLs they can access via fetch() and other HTTP operations.
 *
 * This is used with the WorkerLoader globalOutbound option to enforce
 * HTTP access permissions declared via tools.enableInternet().
 */
export class HttpProxy extends WorkerEntrypoint {
  private allowedPatterns: string[] = [];
  private allowAll: boolean = false;

  /**
   * Initializes the proxy with allowed URL patterns.
   * This method should be called before the proxy is used.
   *
   * @param patterns - Array of URL patterns with wildcard support
   */
  setAllowedPatterns(patterns: string[]): void {
    // Check if unrestricted access is requested
    if (patterns.includes("*")) {
      this.allowAll = true;
      this.allowedPatterns = ["*"];
      return;
    }

    // Merge and deduplicate patterns
    this.allowedPatterns = this.mergePatterns(patterns);
  }

  /**
   * Merges URL patterns, removing redundant ones.
   * For example, if we have both "https://api.example.com/*" and
   * "https://api.example.com/v1/*", we only need the first one.
   */
  private mergePatterns(patterns: string[]): string[] {
    const uniquePatterns = [...new Set(patterns)];

    // Sort patterns by length (shorter patterns are more general)
    uniquePatterns.sort((a, b) => a.length - b.length);

    const merged: string[] = [];

    for (const pattern of uniquePatterns) {
      // Check if this pattern is already covered by a more general pattern
      const isCovered = merged.some((existing) =>
        this.patternCovers(existing, pattern)
      );

      if (!isCovered) {
        merged.push(pattern);
      }
    }

    return merged;
  }

  /**
   * Checks if a general pattern covers a more specific pattern.
   * For example, "https://api.example.com/*" covers "https://api.example.com/v1/*"
   */
  private patternCovers(general: string, specific: string): boolean {
    // Convert pattern to regex
    const regex = this.patternToRegex(general);
    return regex.test(specific.replace(/\*/g, "anything"));
  }

  /**
   * Converts a URL pattern with wildcards to a RegExp.
   * Supports:
   * - * as a standalone pattern (matches everything)
   * - * in hostname for subdomain matching (e.g., https://*.example.com)
   * - * in path for prefix matching (e.g., https://api.example.com/*)
   */
  private patternToRegex(pattern: string): RegExp {
    if (pattern === "*") {
      return /.*/;
    }

    // Escape special regex characters except *
    let regexStr = pattern.replace(/[.+?^${}()|[\]\\]/g, "\\$&");

    // Replace * with appropriate regex patterns
    // Handle protocol wildcards
    regexStr = regexStr.replace(/^(\w+):\/\/\\\*/, "$1://[^/]+");
    // Handle path wildcards (after the domain)
    regexStr = regexStr.replace(/\\\*/g, ".*");

    return new RegExp(`^${regexStr}$`);
  }

  /**
   * Checks if a URL is allowed based on the configured patterns.
   */
  private isAllowed(url: string): boolean {
    if (this.allowAll) {
      return true;
    }

    if (this.allowedPatterns.length === 0) {
      // No patterns configured means deny all
      return false;
    }

    return this.allowedPatterns.some((pattern) => {
      const regex = this.patternToRegex(pattern);
      return regex.test(url);
    });
  }

  /**
   * Handles fetch requests, filtering based on allowed patterns.
   * Authorized requests are forwarded; unauthorized requests are blocked.
   */
  override async fetch(request: Request): Promise<Response> {
    const url = request.url;

    if (!this.isAllowed(url)) {
      return new Response(
        JSON.stringify({
          error: "Forbidden",
          message: `HTTP access to ${url} is not allowed. Request access via tools.enableInternet() in your agent or tool constructor.`,
          url,
        }),
        {
          status: 403,
          headers: { "Content-Type": "application/json" },
        }
      );
    }

    // Forward the request
    return fetch(request);
  }
}

/**
 * Merges URL patterns from multiple sources, removing redundant patterns.
 * Returns null if no permissions (block all), undefined if all access (*),
 * or an array of merged patterns otherwise.
 *
 * @param urlSets - Array of URL pattern arrays from different tools/agents
 * @returns Merged patterns: null (deny all), undefined (allow all), or string[] (specific patterns)
 */
export function mergeHttpPermissions(
  urlSets: string[][]
): string[] | null | undefined {
  if (urlSets.length === 0) {
    // No permissions requested - deny all
    return null;
  }

  // Flatten all URL patterns
  const allUrls = urlSets.flat();

  if (allUrls.length === 0) {
    // Empty arrays mean no permissions - deny all
    return null;
  }

  // Check for unrestricted access
  if (allUrls.includes("*")) {
    // Allow all access
    return undefined;
  }

  // Merge and deduplicate patterns
  const uniquePatterns = [...new Set(allUrls)];
  uniquePatterns.sort((a, b) => a.length - b.length);

  const merged: string[] = [];

  for (const pattern of uniquePatterns) {
    const isCovered = merged.some((existing) => {
      const existingRegex = patternToRegex(existing);
      return existingRegex.test(pattern.replace(/\*/g, "anything"));
    });

    if (!isCovered) {
      merged.push(pattern);
    }
  }

  return merged;
}

/**
 * Helper function to convert a URL pattern to RegExp (used by merge function)
 */
function patternToRegex(pattern: string): RegExp {
  if (pattern === "*") {
    return /.*/;
  }

  let regexStr = pattern.replace(/[.+?^${}()|[\]\\]/g, "\\$&");
  regexStr = regexStr.replace(/^(\w+):\/\/\\\*/, "$1://[^/]+");
  regexStr = regexStr.replace(/\\\*/g, ".*");

  return new RegExp(`^${regexStr}$`);
}
