import { createRequestHandler } from "react-router";

declare global {
  interface CloudflareEnvironment {
    SUPABASE_URL: string;
    SUPABASE_ANON_KEY: string;
    API_ROOT?: string;
  }
}

declare module "react-router" {
  export interface AppLoadContext {
    env: CloudflareEnvironment;
  }
}

const requestHandler = createRequestHandler(
  () => import("virtual:react-router/server-build"),
  import.meta.env.MODE,
);

export default {
  fetch(request, env) {
    return requestHandler(request, {
      env,
    });
  },
} satisfies ExportedHandler<CloudflareEnvironment>;
