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
    // Replace wildcards in the specific pattern with a safe placeholder host
    // and path so it parses as a valid URL, then run the standard match.
    const specificAsUrl = specific
      .replace(/^(\w+):\/\/\*/, "$1://wildcard-host")
      .replace(/\*/g, "anything");
    return this.urlMatchesPattern(specificAsUrl, general);
  }

  /**
   * Parse a wildcard URL pattern into its scheme, hostname, and pathname
   * components so that matching can compare each against `URL` fields rather
   * than the raw URL string.
   *
   * Supports:
   * - "*"                                    -> match anything
   * - "<scheme>://*"                          -> any host (path "*" implicit)
   * - "<scheme>://*.example.com[/path...]"   -> subdomain of example.com
   * - "<scheme>://example.com[/path...]"     -> exact host
   * - Path may end in "/*" (or be just "*") for prefix matching.
   */
  private parsePattern(pattern: string):
    | { kind: "any" }
    | {
        kind: "match";
        protocol: string; // "https:" / "http:"
        hostMode: "any" | "suffix" | "exact";
        hostValue: string; // for suffix/exact
        pathPrefix: string; // path must startWith this (empty string matches all)
      } {
    if (pattern === "*") return { kind: "any" };

    // Pull off the scheme.
    const schemeMatch = pattern.match(/^([a-zA-Z][a-zA-Z0-9+.-]*):\/\/(.*)$/);
    if (!schemeMatch) {
      // Treat as never-matching to be conservative.
      return {
        kind: "match",
        protocol: "__none__:",
        hostMode: "exact",
        hostValue: "__never__",
        pathPrefix: "",
      };
    }
    const protocol = `${schemeMatch[1].toLowerCase()}:`;
    const rest = schemeMatch[2];

    // Split host from path on the first "/".
    const slashIdx = rest.indexOf("/");
    const hostPart = slashIdx === -1 ? rest : rest.slice(0, slashIdx);
    const pathPart = slashIdx === -1 ? "" : rest.slice(slashIdx);

    let hostMode: "any" | "suffix" | "exact";
    let hostValue = "";
    if (hostPart === "*") {
      hostMode = "any";
    } else if (hostPart.startsWith("*.")) {
      hostMode = "suffix";
      hostValue = hostPart.slice(2).toLowerCase();
    } else {
      hostMode = "exact";
      hostValue = hostPart.toLowerCase();
    }

    // Path: "/*" or "" or no leading "/" -> match any. Otherwise require the
    // request path to start with the literal portion up to the first "*".
    let pathPrefix = "";
    if (pathPart === "" || pathPart === "/*") {
      pathPrefix = "";
    } else {
      const wildcardIdx = pathPart.indexOf("*");
      pathPrefix =
        wildcardIdx === -1 ? pathPart : pathPart.slice(0, wildcardIdx);
    }

    return { kind: "match", protocol, hostMode, hostValue, pathPrefix };
  }

  /**
   * Match a fully-formed URL against a single pattern.
   *
   * Parses the URL with `new URL()` and compares hostname / pathname / scheme
   * as structured fields. This avoids the regex-on-raw-URL class of bug where
   * an attacker can hide the real host inside a query string or fragment
   * (e.g. `https://attacker.com?x=.example.com/exfil` matched a pattern of
   * `https://*.example.com/*` because `[^/]+` happily ate the `?x=` chars).
   */
  private urlMatchesPattern(url: string, pattern: string): boolean {
    const parsed = this.parsePattern(pattern);
    if (parsed.kind === "any") return true;

    let parsedUrl: URL;
    try {
      parsedUrl = new URL(url);
    } catch {
      return false;
    }

    // Reject embedded credentials in the URL - easy way for a twist to smuggle
    // tokens to an attacker-controlled host that "looks like" an allowed one.
    if (parsedUrl.username || parsedUrl.password) return false;

    if (parsedUrl.protocol.toLowerCase() !== parsed.protocol) return false;

    const hostname = parsedUrl.hostname.toLowerCase();
    if (parsed.hostMode === "exact") {
      if (hostname !== parsed.hostValue) return false;
    } else if (parsed.hostMode === "suffix") {
      if (
        hostname !== parsed.hostValue &&
        !hostname.endsWith(`.${parsed.hostValue}`)
      ) {
        return false;
      }
    }
    // hostMode === "any": always passes the host check.

    if (parsed.pathPrefix && !parsedUrl.pathname.startsWith(parsed.pathPrefix)) {
      return false;
    }

    return true;
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

    return allowedPatterns.some((pattern) =>
      this.urlMatchesPattern(url, pattern)
    );
  }

  /**
   * Handles fetch requests, filtering based on allowed patterns from props.
   * Authorized requests are forwarded; unauthorized requests are blocked.
   */
  override async fetch(request: Request): Promise<Response> {
    const url = request.url;
    const { allowedPatterns } = this.ctx.props;

    if (!this.isAllowed(url, allowedPatterns)) {
      const message = `HTTP access to ${url} is not allowed. Allowed URL patterns: [${allowedPatterns.join(", ")}]. Add this URL to the Network tool's urls array in your build() method.`;
      const logger = createLogger();
      logger.error(message);
      return new Response(
        JSON.stringify({
          error: "Forbidden",
          message,
          url,
          allowedPatterns,
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
