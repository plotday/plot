import { type TwistPermissions } from "@plotday/twister/tools/twists";

// Re-export TwistPermissions from SDK as TwistPermissions for backwards compatibility
export type { TwistPermissions as TwistPermissions };

/**
 * Permission flags that can be combined for a given domain/entity.
 */
export type PermissionFlag = "read" | "write" | "update" | "use";

/**
 * A single tool permission with domain, entity, and flags.
 * - domain: Tool name (e.g., "network", "plot")
 * - entity: Domain-specific identifier (e.g., URL pattern, resource type)
 * - flags: Array of permission flags
 */
export type ToolPermission = {
  domain: string;
  entity: string;
  flags: PermissionFlag[];
};

/**
 * Merged permissions in nested structure.
 * Format: { domain: { entity: flags[] } }
 * Example: { network: { "https://api.example.com/*": ["use"] } }
 *
 * Note: This type is structurally equivalent to TwistPermissions from the SDK,
 * which uses string[] instead of PermissionFlag[]. They are interchangeable.
 */
export type MergedPermissions = Record<string, Record<string, PermissionFlag[]>>;

/**
 * Consolidates Network tool URL patterns by removing redundant patterns
 * and handling wildcards.
 */
function consolidateNetworkUrls(
  permissions: ToolPermission[]
): ToolPermission[] {
  const urlPatterns = permissions
    .filter((p) => p.domain === "network")
    .map((p) => p.entity);

  if (urlPatterns.length === 0) {
    return [];
  }

  // Check for unrestricted access
  if (urlPatterns.includes("*")) {
    return [{ domain: "network", entity: "*", flags: ["use"] }];
  }

  // Merge and deduplicate patterns
  const uniquePatterns = [...new Set(urlPatterns)];
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

  return merged.map((entity) => ({
    domain: "network",
    entity,
    flags: ["use"],
  }));
}

/**
 * Converts a URL pattern with wildcards to a RegExp.
 * Supports:
 * - * as a standalone pattern (matches everything)
 * - * in hostname for subdomain matching (e.g., https://*.example.com)
 * - * in path for prefix matching (e.g., https://api.example.com/*)
 */
function patternToRegex(pattern: string): RegExp {
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
 * Merges an array of ToolPermissions by:
 * 1. Consolidating Network URLs
 * 2. Grouping by domain and entity
 * 3. ORing (union) flags for matching domain/entity pairs
 * 4. Sorting everything for stable comparison
 */
export function mergeToolPermissions(
  toolPermissions: ToolPermission[]
): MergedPermissions {
  // Consolidate network URLs first
  const networkPerms = consolidateNetworkUrls(toolPermissions);
  const nonNetworkPerms = toolPermissions.filter((p) => p.domain !== "network");
  const allPerms = [...networkPerms, ...nonNetworkPerms];

  // Group by domain and entity, merging flags
  const grouped = new Map<string, Map<string, Set<PermissionFlag>>>();

  for (const perm of allPerms) {
    if (!grouped.has(perm.domain)) {
      grouped.set(perm.domain, new Map());
    }
    const domainMap = grouped.get(perm.domain)!;

    if (!domainMap.has(perm.entity)) {
      domainMap.set(perm.entity, new Set());
    }
    const flagSet = domainMap.get(perm.entity)!;

    // Add all flags (union)
    for (const flag of perm.flags) {
      flagSet.add(flag);
    }
  }

  // Convert to sorted nested structure
  const result: MergedPermissions = {};
  const sortedDomains = Array.from(grouped.keys()).sort();

  for (const domain of sortedDomains) {
    const domainMap = grouped.get(domain)!;
    const sortedEntities = Array.from(domainMap.keys()).sort();

    result[domain] = {};
    for (const entity of sortedEntities) {
      const flags = Array.from(domainMap.get(entity)!).sort();
      result[domain][entity] = flags;
    }
  }

  return result;
}

/**
 * Compares two arrays of ToolPermissions for equality.
 * Sorts both arrays before comparing to handle different orderings.
 */
export function comparePermissions(
  a: ToolPermission[],
  b: ToolPermission[]
): boolean {
  if (a.length !== b.length) {
    return false;
  }

  // Sort both arrays consistently
  const sortedA = [...a].sort((x, y) => {
    if (x.domain !== y.domain) return x.domain.localeCompare(y.domain);
    if (x.entity !== y.entity) return x.entity.localeCompare(y.entity);
    return JSON.stringify(x.flags.sort()) < JSON.stringify(y.flags.sort())
      ? -1
      : 1;
  });

  const sortedB = [...b].sort((x, y) => {
    if (x.domain !== y.domain) return x.domain.localeCompare(y.domain);
    if (x.entity !== y.entity) return x.entity.localeCompare(y.entity);
    return JSON.stringify(x.flags.sort()) < JSON.stringify(y.flags.sort())
      ? -1
      : 1;
  });

  // Deep comparison
  return JSON.stringify(sortedA) === JSON.stringify(sortedB);
}

// Un-merged tool permissions grouped by tool ID (legacy)
export type GroupedPermissions = Record<string, Record<string, object>[]>;

// path (array.join(":")) => permissions (legacy)
export type ToolPermissions = Record<string, Record<string, object>>;

export function groupPermissions(toolPermissions: ToolPermissions) {
  const permissions: GroupedPermissions = {};
  for (const path of Object.keys(toolPermissions)) {
    const id = path.split(":").pop();
    permissions[id!] ??= [];
    permissions[id!].push(toolPermissions[path]);
  }
  return permissions;
}
