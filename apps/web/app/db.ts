import type { AppLoadContext } from "@remix-run/cloudflare";

import { createServerClient as createServerClientHelper } from "@supabase/auth-helpers-remix";
import { createClient } from "@supabase/supabase-js";

import type { Database } from "@plotday/db";

import { authCookieOptions } from "./auth";
import { getEnv } from "./env";

export type { Database, SupabaseClient } from "@plotday/db";

export const createServerClient = (
  request: Request,
  context: AppLoadContext
) => {
  const response = new Response();
  const env = getEnv(context);
  const supabase = createServerClientHelper<Database>(
    env.SUPABASE_URL,
    env.SUPABASE_ANON_KEY,
    {
      request,
      response,
      cookieOptions: authCookieOptions,
    }
  );
  return { response, supabase };
};

export const createServerAdminClient = (context: AppLoadContext) => {
  const env = getEnv(context);
  const supabaseAdmin = createClient<Database>(
    env.SUPABASE_URL,
    env.SUPABASE_SERVICE_KEY,
    {
      auth: {
        persistSession: false,
      },
    }
  );
  return supabaseAdmin;
};
