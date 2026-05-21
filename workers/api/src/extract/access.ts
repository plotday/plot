/**
 * Terminal outcomes for URLs whose content is gated. Distinct from
 * `failed` (which implies an extraction bug or transient problem) and
 * `completed` (which means we have the markdown in R2). UI surfaces just
 * the original link for either of these.
 */
export type AccessStatus = "auth_required" | "paywalled";

type AccessPattern = {
  /**
   * Suffix-matched against the URL's hostname. A pattern of `slack.com`
   * matches both `slack.com` and any subdomain like `mycompany.slack.com`,
   * but not `notslack.com`.
   */
  host: string;
  /**
   * Optional regex tested against the URL's pathname. Use this when the
   * service is partly public — e.g. slack.com's marketing pages are public
   * but `slack.com/archives/...` is auth-only, and Linear paths look like
   * `/<workspace>/issue/<key>` rather than starting with `/issue`.
   */
  path?: RegExp;
};

/**
 * Hosts whose URLs are reliably auth-required. We deliberately exclude
 * services with both public and private modes (GitHub, GitLab, Notion,
 * Google Docs/Drive, Figma, Dropbox, LinkedIn) — those need to attempt
 * extraction and fall back to other failure paths.
 */
const AUTH_REQUIRED: AccessPattern[] = [
  // Atlassian (Jira / Confluence Cloud / Bitbucket-cloud private workspaces)
  { host: "atlassian.net" },
  // Linear issues / projects: paths look like /<workspace>/issue/<key>.
  { host: "linear.app", path: /\/(issue|project)\// },
  // Asana
  { host: "app.asana.com" },
  // Slack messages (slack.com itself is the marketing site)
  { host: "slack.com", path: /^\/archives\// },
  // Microsoft 365 / Teams / Outlook
  { host: "outlook.office.com" },
  { host: "outlook.office365.com" },
  { host: "outlook.live.com" },
  { host: "teams.microsoft.com" },
  // Google Workspace inboxes / calendars
  { host: "mail.google.com" },
  { host: "calendar.google.com" },
  // CRMs & support
  { host: "app.hubspot.com" },
  { host: "app.intercom.com" },
  { host: "app.frontapp.com" },
  { host: "app.salesforce.com" },
  { host: "lightning.force.com" },
  { host: "my.salesforce.com" },
  // Project / ticketing
  { host: "app.shortcut.com" },
  { host: "app.clickup.com" },
  // Notetaking / docs that are auth-only by default for editing surfaces
  { host: "app.frame.io" },
];

/**
 * Hosts where the vast majority of articles are paywalled. We accept some
 * false positives here (a few free articles per outlet) — the user's
 * stated preference is to skip extraction rather than waste cycles on
 * content we usually can't read. Outlets with predominantly metered or
 * partial paywalls (Medium, Substack, NY Mag) are NOT in this list.
 */
const PAYWALLED: AccessPattern[] = [
  { host: "ft.com" },
  { host: "wsj.com" },
  { host: "bloomberg.com" },
  { host: "economist.com" },
  { host: "nytimes.com" },
  { host: "newyorker.com" },
  { host: "theatlantic.com" },
  { host: "washingtonpost.com" },
  { host: "theinformation.com" },
  { host: "bostonglobe.com" },
  { host: "latimes.com" },
  { host: "foreignaffairs.com" },
  { host: "hbr.org" },
  { host: "barrons.com" },
];

function hostMatches(hostname: string, suffix: string): boolean {
  if (hostname === suffix) return true;
  if (hostname.endsWith("." + suffix)) return true;
  return false;
}

function patternMatches(
  hostname: string,
  pathname: string,
  pattern: AccessPattern
): boolean {
  if (!hostMatches(hostname, pattern.host)) return false;
  if (pattern.path && !pattern.path.test(pathname)) return false;
  return true;
}

/**
 * Pre-flight check that classifies URLs whose content we know we can't
 * extract. Called before queueing so we never spend an extraction session
 * (or a Browser Rendering session) on auth walls or hard paywalls.
 *
 * Returns `null` when the URL doesn't match any known pattern; callers
 * should proceed with normal extraction and let runtime detection handle
 * any auth/paywall signals we can only spot after fetching.
 */
export function classifyUrlAccess(url: string): AccessStatus | null {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return null;
  }
  const host = parsed.hostname.toLowerCase();
  const path = parsed.pathname;

  for (const p of AUTH_REQUIRED) {
    if (patternMatches(host, path, p)) return "auth_required";
  }
  for (const p of PAYWALLED) {
    if (patternMatches(host, path, p)) return "paywalled";
  }
  return null;
}
