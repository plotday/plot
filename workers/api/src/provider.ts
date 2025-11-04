import { type AuthProvider } from "@plotday/agent/tools/integrations";

type ProviderConfig = {
  name: string;
  authUrl: string;
  tokenUrl: string;
  additionalParams?: Record<string, string>;
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
