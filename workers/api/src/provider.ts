import { type AuthProvider } from "@plotday/agent/tools/auth";

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
};
