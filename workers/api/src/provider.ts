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
  bot_user_id: string;
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
  email: string;
};

export type LinearProviderData = {
  email: string;
};

// Union of all provider-specific data types
export type ProviderData =
  | SlackProviderData
  | GoogleProviderData
  | MicrosoftProviderData
  | GitHubProviderData
  | LinearProviderData;

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

// Helper function to fetch email from GitHub API
async function fetchGitHubEmail(accessToken: string): Promise<string | null> {
  try {
    const response = await fetch("https://api.github.com/user", {
      headers: {
        Authorization: `Bearer ${accessToken}`,
        Accept: "application/vnd.github.v3+json",
      },
    });

    if (!response.ok) {
      return null;
    }

    const data = await response.json() as { email?: string };
    return data.email || null;
  } catch (error) {
    const logger = createLogger({ component: "provider" });
    logger.error("Error fetching GitHub email", error as Error);
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

  const email = await fetchGitHubEmail(response.access_token);
  if (!email) {
    return undefined;
  }

  return { email };
};

// Helper function to fetch email from Linear API
async function fetchLinearEmail(accessToken: string): Promise<string | null> {
  try {
    const response = await fetch("https://api.linear.app/graphql", {
      method: "POST",
      headers: {
        Authorization: accessToken,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ query: "{ viewer { email } }" }),
    });

    if (!response.ok) {
      return null;
    }

    const data = (await response.json()) as {
      data?: { viewer?: { email?: string } };
    };
    return data.data?.viewer?.email || null;
  } catch (error) {
    const logger = createLogger({ component: "provider" });
    logger.error("Error fetching Linear email", error as Error);
    return null;
  }
}

const parseLinearTokenResponse = async (
  response: any
): Promise<LinearProviderData | undefined> => {
  if (!response.access_token) {
    return undefined;
  }

  const email = await fetchLinearEmail(response.access_token);
  if (!email) {
    return undefined;
  }

  return { email };
};

type ProviderConfig = {
  name: string;
  authUrl: string;
  tokenUrl: string;
  additionalParams?: Record<string, string>;
  // Email scopes that should always be included
  emailScopes?: string[];
  // Parse provider-specific fields from OAuth token response (can be async for API calls)
  parseTokenResponse?: (
    response: any
  ) => ProviderData | undefined | Promise<ProviderData | undefined>;
  // Extract metadata for AuthToken.provider field
  extractMetadata?: (providerData: ProviderData) => Record<string, string> | undefined;
};

export const PROVIDER_CONFIGS: Record<AuthProvider, ProviderConfig> = {
  google: {
    name: "Google",
    authUrl: "https://accounts.google.com/o/oauth2/v2/auth",
    tokenUrl: "https://oauth2.googleapis.com/token",
    emailScopes: ["openid", "email"],
    parseTokenResponse: parseGoogleTokenResponse,
    additionalParams: {
      access_type: "offline",
      prompt: "select_account consent",  // Google supports combined values
    },
  },
  microsoft: {
    name: "Microsoft",
    authUrl: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
    tokenUrl: "https://login.microsoftonline.com/common/oauth2/v2.0/token",
    emailScopes: ["openid", "email"],
    parseTokenResponse: parseMicrosoftTokenResponse,
    additionalParams: {
      prompt: "consent",  // Microsoft only supports single values; consent ensures permission screen shows
    },
  },
  notion: {
    name: "Notion",
    authUrl: "https://api.notion.com/v1/oauth/authorize",
    tokenUrl: "https://api.notion.com/v1/oauth/token",
  },
  slack: {
    name: "Slack",
    authUrl: "https://slack.com/oauth/v2/authorize",
    tokenUrl: "https://slack.com/api/oauth.v2.access",
    parseTokenResponse: (response: any): SlackProviderData | undefined => {
      if (!response.ok) {
        return undefined;
      }
      return {
        token_type: response.token_type,
        bot_user_id: response.bot_user_id,
        team: response.team,
        enterprise: response.enterprise,
        authed_user: response.authed_user,
      };
    },
    extractMetadata: (providerData: ProviderData): Record<string, string> | undefined => {
      // Type guard to check if it's SlackProviderData
      const slackData = providerData as SlackProviderData;
      const metadata: Record<string, string> = {};

      if (slackData.authed_user?.id) {
        metadata.authed_user_id = slackData.authed_user.id;
      }
      if (slackData.bot_user_id) {
        metadata.bot_user_id = slackData.bot_user_id;
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
  },
  atlassian: {
    name: "Atlassian",
    authUrl: "https://auth.atlassian.com/authorize",
    tokenUrl: "https://auth.atlassian.com/oauth/token",
    additionalParams: {
      audience: "api.atlassian.com",
    },
  },
  linear: {
    name: "Linear",
    authUrl: "https://linear.app/oauth/authorize",
    tokenUrl: "https://api.linear.app/oauth/token",
    parseTokenResponse: parseLinearTokenResponse,
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
    emailScopes: ["user:email"],
    parseTokenResponse: parseGitHubTokenResponse,
  },
  asana: {
    name: "Asana",
    authUrl: "https://app.asana.com/-/oauth_authorize",
    tokenUrl: "https://app.asana.com/-/oauth_token",
  },
  hubspot: {
    name: "HubSpot",
    authUrl: "https://app.hubspot.com/oauth/authorize",
    tokenUrl: "https://api.hubapi.com/oauth/v1/token",
  },
};
