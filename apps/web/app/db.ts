import type { AppLoadContext } from "@remix-run/cloudflare";

import {
  createServerClient as createServerClientHelper,
  parse,
  serialize,
} from "@supabase/ssr";
import { createClient } from "@supabase/supabase-js";

import type { Database } from "@plotday/db";

import { getEnv } from "./env.server";

export type { Database, SupabaseClient } from "@plotday/db";
export { safeQuery } from "@plotday/db";

export const createServerClient = (
  request: Request,
  context: AppLoadContext
) => {
  const response = new Response();
  const env = getEnv(context);

  const cookies = parse(request.headers.get("Cookie") ?? "");
  const supabase = createServerClientHelper<Database>(
    env.SUPABASE_URL,
    env.SUPABASE_ANON_KEY,
    {
      cookies: {
        get(key) {
          return cookies[key];
        },
        set(key, value, options) {
          response.headers.append("Set-Cookie", serialize(key, value, options));
        },
        remove(key, options) {
          response.headers.append("Set-Cookie", serialize(key, "", options));
        },
      },
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
