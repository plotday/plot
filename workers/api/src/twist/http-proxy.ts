import { WorkerEntrypoint } from "cloudflare:workers";

import { createLogger } from "@plotday/worker-util";

/**
 * HttpProxy acts as an outbound filter for twist workers, controlling which
 * URLs they can access via fetch() and other HTTP operations.
 *
 * This is used with the WorkerLoader globalOutbound option to enforce
 * HTTP access permissions declared via tools.get(Network, { urls: [...] }).
 *
 * Props are passed when the proxy is configured as globalOutbound, providing
 * the specific URL patterns allowed for each twist worker.
 */
export class HttpProxy extends WorkerEntrypoint<
  {}, // No special env bindings needed
  { allowedPatterns: string[] } // Props containing URL patterns
> {
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
    regexStr = regexStr.replace(/^(\w+):\/\/\*/, "$1://[^/]+");
    // Handle path wildcards (after the domain)
    regexStr = regexStr.replace(/\*/g, ".*");

    return new RegExp(`^${regexStr}$`);
  }

  /**
   * Checks if a URL is allowed based on the provided patterns.
   *
   * @param url - The URL to check
   * @param allowedPatterns - Array of URL patterns to check against
   */
  private isAllowed(url: string, allowedPatterns: string[]): boolean {
    // Check for unrestricted access
    if (allowedPatterns.includes("*")) {
      return true;
    }

    if (allowedPatterns.length === 0) {
      // No patterns configured means deny all
      const logger = createLogger();
      logger.warn("HTTP Proxy: No allowed patterns configured, denying all requests");
      return false;
    }

    return allowedPatterns.some((pattern) => {
      const regex = this.patternToRegex(pattern);
      return regex.test(url);
    });
  }

  /**
   * Handles fetch requests, filtering based on allowed patterns from props.
   * Authorized requests are forwarded; unauthorized requests are blocked.
   */
  override async fetch(request: Request): Promise<Response> {
    const url = request.url;
    const { allowedPatterns } = this.ctx.props;

    if (!this.isAllowed(url, allowedPatterns)) {
      return new Response(
        JSON.stringify({
          error: "Forbidden",
          message: `HTTP access to ${url} is not allowed. Request access via tools.get(Network, { urls: [...] }) in your twist or tool constructor.`,
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
