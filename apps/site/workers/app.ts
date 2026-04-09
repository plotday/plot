import { createRequestHandler } from "react-router";

declare global {
  interface CloudflareEnvironment {
    CLERK_SECRET_KEY: string;
    CLERK_PUBLISHABLE_KEY: string;
    API_ROOT?: string;
    APP_ROOT?: string;
    POSTHOG_API_KEY?: string;
    POSTHOG_PROXY?: string;
    VOTES?: KVNamespace;
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
    // Clerk SDK reads these from globalThis on Cloudflare Workers
    (globalThis as Record<string, unknown>).CLERK_SECRET_KEY = env.CLERK_SECRET_KEY;
    (globalThis as Record<string, unknown>).CLERK_PUBLISHABLE_KEY = env.CLERK_PUBLISHABLE_KEY;

    const response = await requestHandler(request, {
      cloudflare: { env, ctx },
    });

    // Add CORS headers for static assets so they can be loaded cross-origin
    const url = new URL(request.url);
    if (url.pathname.startsWith("/assets/")) {
      const corsResponse = new Response(response.body, response);
      corsResponse.headers.set("Access-Control-Allow-Origin", "*");
      return corsResponse;
    }

    return response;
  },
} satisfies ExportedHandler<CloudflareEnvironment>;
