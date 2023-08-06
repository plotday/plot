import type { AppLoadContext } from "@remix-run/cloudflare";
import { createServerClient as createServerClientHelper } from "@supabase/auth-helpers-remix";
import { createClient } from "@supabase/supabase-js";

import type { Database } from "@plotday/db";

import { authCookieOptions } from "./auth";
import { getEnv } from "./env";

export type { Database } from "@plotday/db";
export { safeQuery } from "@plotday/db";

export const createServerClient = (
  request: Request,
  context: AppLoadContext
) => {
  const response = new Response();
  const supabase = createServerClientHelper<Database>(
    getEnv(context).SUPABASE_URL,
    getEnv(context).SUPABASE_ANON_KEY,
    {
      request,
      response,
      cookieOptions: authCookieOptions,
    }
  );
  return { response, supabase };
};

export const createServerAdminClient = (context: AppLoadContext) => {
  const supabaseAdmin = createClient<Database>(
    getEnv(context).SUPABASE_URL,
    getEnv(context).SUPABASE_SERVICE_KEY,
    {
      auth: {
        persistSession: false,
      },
    }
  );
  return supabaseAdmin;
};
