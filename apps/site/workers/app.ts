import { createRequestHandler } from "react-router";

declare global {
  interface CloudflareEnvironment {
    SUPABASE_URL: string;
    SUPABASE_ANON_KEY: string;
    API_ROOT?: string;
    APP_ROOT?: string;
  }
}

declare module "react-router" {
  export interface AppLoadContext {
    cloudflare: {
      env: CloudflareEnvironment;
      ctx: ExecutionContext;
    };
  }
}

const requestHandler = createRequestHandler(
  () => import("virtual:react-router/server-build"),
  import.meta.env.MODE,
);

export default {
  async fetch(request, env, ctx) {
    return requestHandler(request, {
      cloudflare: { env, ctx },
    });
  },
} satisfies ExportedHandler<CloudflareEnvironment>;
