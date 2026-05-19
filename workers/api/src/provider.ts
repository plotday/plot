import { type AuthProvider } from "@plotday/twister/tools/integrations";
import { createLogger } from "@plotday/worker-util";

// Base OAuth token data (common to all providers)
export type BaseTokenData = {
  access_token: string;
  refresh_token: string | null;
  expires_at: number | null;
  scopes: string[];
  client_id: string;
};

// Provider-specific data types
export type SlackProviderData = {
  token_type: string;
  team: { id: string; name: string };
  enterprise?: { id: string; name: string };
  authed_user: { id: string; access_token: string; scope: string };
  email?: string;
};

export type GoogleProviderData = {
  email: string;
  email_verified?: boolean;
};

export type MicrosoftProviderData = {
  email: string;
};

export type GitHubProviderData = {
  email: string | null;
  userId: string;
  login: string;
};

export type LinearProviderData = {
  email: string | null;
  userId: string;
  organizationName: string | null;
};

export type AtlassianProviderData = {
  cloudId: string | null;
  siteName: string | null;
};

export type NotionProviderData = {
  workspaceName: string | null;
  workspaceId: string | null;
};

export type AsanaProviderData = {
  email: string | null;
  name: string | null;
};

export type TodoistProviderData = {
  email: string | null;
  fullName: string | null;
};

export type AirtableProviderData = {
  userId: string;
  email: string | null;
};

// LinkedIn uses a captured `li_at` session cookie (not OAuth), plus a few
// extras the Voyager API needs on every request:
//  - `jsessionid` doubles as the CSRF token (sent as the `csrf-token` header)
//  - `userAgent` is pinned to the device that captured the cookie so the
//    server-side fingerprint matches the client's
//  - the profile triple identifies the connected account and gives the
//    Connections UI a label without an extra round-trip
//
// Uses `email` and `userId` to match the conventions extractEmail /
// extractUserId expect.
export type LinkedInProviderData = {
  jsessionid: string;
  userAgent: string;
  platform: "ios" | "android" | "desktop" | "web";
  userId: string;     // urn:li:fsd_profile:<id>
  fullName: string;
  email: string | null;
};

// Union of all provider-specific data types
export type ProviderData =
  | SlackProviderData
  | GoogleProviderData
  | MicrosoftProviderData
  | GitHubProviderData
  | LinearProviderData
  | AtlassianProviderData
  | NotionProviderData
  | AsanaProviderData
  | TodoistProviderData
  | AirtableProviderData
  | LinkedInProviderData;

// Combined storage type
export type StoredTokenData = BaseTokenData & {
  providerData: ProviderData | null;
};

// Helper function to decode JWT and extract email
function parseJwtEmail(idToken: string): string | null {
  try {
    // JWT is base64url encoded: header.payload.signature
    const parts = idToken.split(".");
    if (parts.length !== 3) {
      return null;
    }

    // Decode the payload (second part)
    const payload = parts[1];
    // Convert base64url to base64
    const base64 = payload.replace(/-/g, "+").replace(/_/g, "/");
    // Decode base64
    const jsonPayload = atob(base64);
    const data = JSON.parse(jsonPayload);

    return data.email || null;
  } catch (error) {
    const logger = createLogger({ component: "provider" });
    logger.error("Error parsing JWT", error as Error);
    return null;
  }
}

// Helper function to fetch user info from GitHub API
async function fetchGitHubUser(accessToken: string): Promise<{ userId: string; email: string | null; login: string } | null> {
  try {
    const response = await fetch("https://api.github.com/user", {
      headers: {
        Authorization: `Bearer ${accessToken}`,
        Accept: "application/vnd.github.v3+json",
        // GitHub requires a User-Agent on every request; without one the API
        // returns 403 and we fall through to a null account label.
        "User-Agent": "Plot",
      },
    });

    if (!response.ok) {
      return null;
    }

    const data = await response.json() as { id?: number; email?: string; login?: string };
    if (!data.id || !data.login) {
      return null;
    }

    return { userId: String(data.id), email: data.email || null, login: data.login };
  } catch (error) {
    const logger = createLogger({ component: "provider" });
    logger.error("Error fetching GitHub user", error as Error);
    return null;
  }
}

// Parse token response functions for providers
const parseGoogleTokenResponse = (
  response: any
): GoogleProviderData | undefined => {
  if (!response.id_token) {
    return undefined;
  }

  const email = parseJwtEmail(response.id_token);
  if (!email) {
    return undefined;
  }

  return {
    email,
    email_verified: true, // Google id_token implies verification
  };
};

const parseMicrosoftTokenResponse = (
  response: any
): MicrosoftProviderData | undefined => {
  if (!response.id_token) {
    return undefined;
  }

  const email = parseJwtEmail(response.id_token);
  if (!email) {
    return undefined;
  }

  return { email };
};

const parseGitHubTokenResponse = async (
  response: any
): Promise<GitHubProviderData | undefined> => {
  if (!response.access_token) {
    return undefined;
  }

  const user = await fetchGitHubUser(response.access_token);
  if (!user) {
    return undefined;
  }

  return { email: user.email, userId: user.userId, login: user.login };
};

// Helper function to fetch viewer + organization info from Linear API
async function fetchLinearViewer(accessToken: string): Promise<{ userId: string; email: string | null; organizationName: string | null } | null> {
  try {
    const response = await fetch("https://api.linear.app/graphql", {
      method: "POST",
      headers: {
        Authorization: accessToken,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ query: "{ viewer { id email } organization { name } }" }),
    });

    if (!response.ok) {
      return null;
    }

    const data = (await response.json()) as {
      data?: {
        viewer?: { id?: string; email?: string };
        organization?: { name?: string };
      };
    };
    const viewer = data.data?.viewer;
    if (!viewer?.id) {
      return null;
    }

    return {
      userId: viewer.id,
      email: viewer.email || null,
      organizationName: data.data?.organization?.name || null,
    };
  } catch (error) {
    const logger = createLogger({ component: "provider" });
    logger.error("Error fetching Linear viewer", error as Error);
    return null;
  }
}

// Fetch the first accessible Atlassian site (cloudId + name)
async function fetchAtlassianSite(accessToken: string): Promise<{ cloudId: string; siteName: string | null } | null> {
  try {
    const response = await fetch("https://api.atlassian.com/oauth/token/accessible-resources", {
      headers: {
        Authorization: `Bearer ${accessToken}`,
        Accept: "application/json",
      },
    });
    if (!response.ok) return null;
    const sites = (await response.json()) as Array<{ id?: string; name?: string; url?: string }>;
    const first = sites?.[0];
    if (!first?.id) return null;
    return { cloudId: first.id, siteName: first.name || first.url || null };
  } catch (error) {
    const logger = createLogger({ component: "provider" });
    logger.error("Error fetching Atlassian accessible-resources", error as Error);
    return null;
  }
}

const parseAtlassianTokenResponse = async (
  response: any
): Promise<AtlassianProviderData | undefined> => {
  if (!response.access_token) return undefined;
  const site = await fetchAtlassianSite(response.access_token);
  return {
    cloudId: site?.cloudId ?? null,
    siteName: site?.siteName ?? null,
  };
};

const parseNotionTokenResponse = (
  response: any
): NotionProviderData | undefined => {
  if (!response.access_token) return undefined;
  return {
    workspaceName: response.workspace_name || null,
    workspaceId: response.workspace_id || null,
  };
};

async function fetchAsanaUser(accessToken: string): Promise<{ email: string | null; name: string | null } | null> {
  try {
    const response = await fetch("https://app.asana.com/api/1.0/users/me", {
      headers: { Authorization: `Bearer ${accessToken}` },
    });
    if (!response.ok) return null;
    const data = (await response.json()) as { data?: { email?: string; name?: string } };
    return {
      email: data.data?.email || null,
      name: data.data?.name || null,
    };
  } catch (error) {
    const logger = createLogger({ component: "provider" });
    logger.error("Error fetching Asana user", error as Error);
    return null;
  }
}

const parseAsanaTokenResponse = async (
  response: any
): Promise<AsanaProviderData | undefined> => {
  if (!response.access_token) return undefined;
  const user = await fetchAsanaUser(response.access_token);
  return {
    email: user?.email ?? null,
    name: user?.name ?? null,
  };
};

async function fetchTodoistUser(accessToken: string): Promise<{ email: string | null; fullName: string | null } | null> {
  try {
    const response = await fetch("https://api.todoist.com/sync/v9/sync", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: 'sync_token=*&resource_types=["user"]',
    });
    if (!response.ok) return null;
    const data = (await response.json()) as { user?: { email?: string; full_name?: string } };
    return {
      email: data.user?.email || null,
      fullName: data.user?.full_name || null,
    };
  } catch (error) {
    const logger = createLogger({ component: "provider" });
    logger.error("Error fetching Todoist user", error as Error);
    return null;
  }
}

const parseTodoistTokenResponse = async (
  response: any
): Promise<TodoistProviderData | undefined> => {
  if (!response.access_token) return undefined;
  const user = await fetchTodoistUser(response.access_token);
  return {
    email: user?.email ?? null,
    fullName: user?.fullName ?? null,
  };
};

async function fetchAirtableUser(accessToken: string): Promise<{ userId: string; email: string | null } | null> {
  try {
    const response = await fetch("https://api.airtable.com/v0/meta/whoami", {
      headers: { Authorization: `Bearer ${accessToken}` },
    });
    if (!response.ok) return null;
    const data = (await response.json()) as { id?: string; email?: string };
    if (!data.id) return null;
    return { userId: data.id, email: data.email || null };
  } catch (error) {
    const logger = createLogger({ component: "provider" });
    logger.error("Error fetching Airtable user", error as Error);
    return null;
  }
}

const parseAirtableTokenResponse = async (
  response: any
): Promise<AirtableProviderData | undefined> => {
  if (!response.access_token) return undefined;
  const user = await fetchAirtableUser(response.access_token);
  if (!user) return undefined;
  return { userId: user.userId, email: user.email };
};

const parseLinearTokenResponse = async (
  response: any
): Promise<LinearProviderData | undefined> => {
  if (!response.access_token) {
    return undefined;
  }

  const viewer = await fetchLinearViewer(response.access_token);
  if (!viewer) {
    return undefined;
  }

  return {
    email: viewer.email,
    userId: viewer.userId,
    organizationName: viewer.organizationName,
  };
};

type ProviderConfig = {
  name: string;
  // Omitted for non-OAuth providers (e.g. LinkedIn cookie auth). When absent,
  // GenerateAuthUrl / HandleOauthCallback refuse to handle this provider —
  // the client must use the provider's dedicated auth endpoint instead.
  authUrl?: string;
  tokenUrl?: string;
  additionalParams?: Record<string, string>;
  // When true, send client_id/client_secret via HTTP Basic Authentication
  // header on the token endpoint instead of the request body. Required by
  // providers like Airtable for confidential integrations.
  useBasicAuth?: boolean;
  // When true, the provider rejects custom URI schemes (e.g. plotday://) as
  // redirect URIs, so we register only HTTPS callbacks and bridge custom
  // schemes via a server-rendered page. See GET /auth/bridge.
  requiresHttpsRedirect?: boolean;
  // Email scopes that should always be included
  emailScopes?: string[];
  // Query parameter name used to pass scopes on the authorization URL. Most
  // providers use "scope" (the OAuth 2.0 default). Slack v2 treats "scope" as
  // bot scopes; user-token-only apps must pass user scopes via "user_scope"
  // instead, otherwise the workspace install page returns "Invalid permissions
  // requested".
  scopeParam?: string;
  // Parse provider-specific fields from OAuth token response (can be async for API calls)
  parseTokenResponse?: (
    response: any
  ) => ProviderData | undefined | Promise<ProviderData | undefined>;
  // Pick the effective access_token from the raw token-exchange response when
  // it isn't at the default `response.access_token` location. Slack v2 apps
  // that request only user scopes return the user token at
  // `authed_user.access_token`, so we remap it here.
  extractAccessToken?: (response: any) => string | undefined;
  // Extract metadata for AuthToken.provider field
  extractMetadata?: (providerData: ProviderData) => Record<string, string> | undefined;
  // Extract the per-connection account label shown as disambiguator in the
  // Connections UI and composed into the actor display name for notes/mentions.
  // Return null when the provider exposes no natural label — the client will
  // then require the user to enter one.
  extractAccountLabel?: (providerData: ProviderData) => string | null;
};

/**
 * Extract the provider-specific user ID from provider data.
 * Returns null if provider data is missing or doesn't contain a user ID.
 */
export function extractUserId(provider: AuthProvider, providerData: ProviderData | null): string | null {
  if (!providerData) return null;
  switch (provider) {
    case "github":
    case "linear":
    case "airtable":
      return (providerData as GitHubProviderData | LinearProviderData | AirtableProviderData).userId ?? null;
    case "slack":
      return (providerData as SlackProviderData).authed_user?.id ?? null;
    case "linkedin":
      return (providerData as LinkedInProviderData).userId ?? null;
    default:
      return null;
  }
}

export const PROVIDER_CONFIGS: Record<AuthProvider, ProviderConfig> = {
  google: {
    name: "Google",
    authUrl: "https://accounts.google.com/o/oauth2/v2/auth",
    tokenUrl: "https://oauth2.googleapis.com/token",
    emailScopes: ["openid", "email"],
    parseTokenResponse: parseGoogleTokenResponse,
    extractAccountLabel: (d) => (d as GoogleProviderData).email || null,
    additionalParams: {
      access_type: "offline",
      prompt: "select_account",
      // Incremental authorization: token carries previously granted scopes,
      // but the consent screen lists only newly requested ones.
      include_granted_scopes: "true",
    },
  },
  microsoft: {
    name: "Microsoft",
    authUrl: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
    tokenUrl: "https://login.microsoftonline.com/common/oauth2/v2.0/token",
    emailScopes: ["openid", "email"],
    parseTokenResponse: parseMicrosoftTokenResponse,
    extractAccountLabel: (d) => (d as MicrosoftProviderData).email || null,
    additionalParams: {
      prompt: "consent",  // Microsoft only supports single values; consent ensures permission screen shows
    },
  },
  notion: {
    name: "Notion",
    authUrl: "https://api.notion.com/v1/oauth/authorize",
    tokenUrl: "https://api.notion.com/v1/oauth/token",
    parseTokenResponse: parseNotionTokenResponse,
    extractAccountLabel: (d) => (d as NotionProviderData).workspaceName || null,
  },
  slack: {
    name: "Slack",
    authUrl: "https://slack.com/oauth/v2/authorize",
    tokenUrl: "https://slack.com/api/oauth.v2.access",
    // Slack rejects custom URI schemes (plotday://) — always route through
    // the https bridge endpoint, which deep-links back to the client.
    requiresHttpsRedirect: true,
    // User-token-only app: scopes must ride on `user_scope`, not `scope`.
    scopeParam: "user_scope",
    // User-scope-only apps return the user token at `authed_user.access_token`;
    // the top-level `access_token` may be absent. Fall back to it to stay
    // compatible with any legacy tokens still in storage.
    extractAccessToken: (r) => r?.authed_user?.access_token ?? r?.access_token,
    parseTokenResponse: (response: any): SlackProviderData | undefined => {
      if (!response.ok) {
        return undefined;
      }
      return {
        token_type: response.token_type,
        team: response.team,
        enterprise: response.enterprise,
        authed_user: response.authed_user,
      };
    },
    extractMetadata: (providerData: ProviderData): Record<string, string> | undefined => {
      const slackData = providerData as SlackProviderData;
      const metadata: Record<string, string> = {};

      if (slackData.authed_user?.id) {
        metadata.authed_user_id = slackData.authed_user.id;
      }
      if (slackData.team?.name) {
        metadata.team_name = slackData.team.name;
      }
      if (slackData.team?.id) {
        metadata.team_id = slackData.team.id;
      }
      if (slackData.enterprise?.id) {
        metadata.enterprise_id = slackData.enterprise.id;
      }

      return Object.keys(metadata).length > 0 ? metadata : undefined;
    },
    extractAccountLabel: (d) => {
      const s = d as SlackProviderData;
      return s.team?.name ?? s.enterprise?.name ?? null;
    },
  },
  atlassian: {
    name: "Atlassian",
    authUrl: "https://auth.atlassian.com/authorize",
    tokenUrl: "https://auth.atlassian.com/oauth/token",
    additionalParams: {
      audience: "api.atlassian.com",
    },
    parseTokenResponse: parseAtlassianTokenResponse,
    extractMetadata: (providerData: ProviderData): Record<string, string> | undefined => {
      const a = providerData as AtlassianProviderData;
      const metadata: Record<string, string> = {};
      if (a.cloudId) metadata.cloud_id = a.cloudId;
      if (a.siteName) metadata.site_name = a.siteName;
      return Object.keys(metadata).length > 0 ? metadata : undefined;
    },
    extractAccountLabel: (d) => (d as AtlassianProviderData).siteName || null,
  },
  linear: {
    name: "Linear",
    authUrl: "https://linear.app/oauth/authorize",
    tokenUrl: "https://api.linear.app/oauth/token",
    parseTokenResponse: parseLinearTokenResponse,
    extractAccountLabel: (d) => {
      const l = d as LinearProviderData;
      return l.organizationName || l.email || null;
    },
  },
  monday: {
    name: "Monday.com",
    authUrl: "https://auth.monday.com/oauth2/authorize",
    tokenUrl: "https://auth.monday.com/oauth2/token",
  },
  github: {
    name: "GitHub",
    authUrl: "https://github.com/login/oauth/authorize",
    tokenUrl: "https://github.com/login/oauth/access_token",
    // GitHub OAuth Apps only allow a single registered callback URL and
    // reject custom URI schemes / loopback addresses, so route every flow
    // through the https bridge endpoint.
    requiresHttpsRedirect: true,
    emailScopes: ["user:email"],
    parseTokenResponse: parseGitHubTokenResponse,
    extractAccountLabel: (d) => {
      const g = d as GitHubProviderData;
      return g.login || g.email || null;
    },
  },
  asana: {
    name: "Asana",
    authUrl: "https://app.asana.com/-/oauth_authorize",
    tokenUrl: "https://app.asana.com/-/oauth_token",
    parseTokenResponse: parseAsanaTokenResponse,
    extractAccountLabel: (d) => {
      const a = d as AsanaProviderData;
      return a.email || a.name || null;
    },
  },
  hubspot: {
    name: "HubSpot",
    authUrl: "https://app.hubspot.com/oauth/authorize",
    tokenUrl: "https://api.hubapi.com/oauth/v1/token",
  },
  todoist: {
    name: "Todoist",
    authUrl: "https://todoist.com/oauth/authorize",
    tokenUrl: "https://todoist.com/oauth/access_token",
    parseTokenResponse: parseTodoistTokenResponse,
    extractAccountLabel: (d) => {
      const t = d as TodoistProviderData;
      return t.email || t.fullName || null;
    },
  },
  airtable: {
    name: "Airtable",
    authUrl: "https://airtable.com/oauth2/v1/authorize",
    tokenUrl: "https://airtable.com/oauth2/v1/token",
    useBasicAuth: true,
    requiresHttpsRedirect: true,
    parseTokenResponse: parseAirtableTokenResponse,
    extractAccountLabel: (d) => (d as AirtableProviderData).email || null,
  },
  linkedin: {
    name: "LinkedIn",
    // Cookie-based auth: no OAuth endpoints. The client posts the captured
    // li_at cookie to POST /twist/:id/integrations/linkedin/cookie instead
    // of going through GenerateAuthUrl / HandleOauthCallback. The endpoint
    // assembles a synthetic OAuth-shaped tokenInfo and invokes the
    // connector's `onAuth` callback; this parser then lifts the
    // LinkedIn-specific fields out of that tokenInfo.
    parseTokenResponse: (response: any): LinkedInProviderData | undefined => {
      if (
        !response?.access_token ||
        !response?.jsessionid ||
        !response?.userAgent ||
        !response?.userId
      ) {
        return undefined;
      }
      const platform = response.platform as
        | "ios"
        | "android"
        | "desktop"
        | "web"
        | undefined;
      return {
        jsessionid: response.jsessionid,
        userAgent: response.userAgent,
        platform: platform ?? "web",
        userId: response.userId,
        fullName: response.fullName ?? "",
        email: response.email ?? null,
      };
    },
    extractAccountLabel: (d) => {
      const li = d as LinkedInProviderData;
      return li.fullName || li.email || null;
    },
  },
};
