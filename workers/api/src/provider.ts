import { type AuthProvider } from "@plotday/twister/tools/integrations";

// Base OAuth token data (common to all providers)
export type BaseTokenData = {
  access_token: string;
  refresh_token?: string;
  expires_at?: number;
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
};

// Union of all provider-specific data types
export type ProviderData = SlackProviderData;

// Combined storage type
export type StoredTokenData = BaseTokenData & {
  providerData?: ProviderData;
};

type ProviderConfig = {
  name: string;
  authUrl: string;
  tokenUrl: string;
  additionalParams?: Record<string, string>;
  // Parse provider-specific fields from OAuth token response
  parseTokenResponse?: (response: any) => ProviderData | undefined;
  // Extract metadata for AuthToken.provider field
  extractMetadata?: (providerData: ProviderData) => Record<string, string> | undefined;
};

export const PROVIDER_CONFIGS: Record<AuthProvider, ProviderConfig> = {
  google: {
    name: "Google",
    authUrl: "https://accounts.google.com/o/oauth2/v2/auth",
    tokenUrl: "https://oauth2.googleapis.com/token",
    additionalParams: {
      access_type: "offline",
      prompt: "select_account consent",
    },
  },
  microsoft: {
    name: "Microsoft",
    authUrl: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
    tokenUrl: "https://login.microsoftonline.com/common/oauth2/v2.0/token",
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
