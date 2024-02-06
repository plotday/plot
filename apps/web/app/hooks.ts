import { useOutletContext } from "@remix-run/react";

import type { SupabaseClient, User } from "@supabase/supabase-js";

import type { Database } from "@plotday/db";

import type { getBrowserEnv } from "./env.server";

export type ContextType = {
  supabase?: SupabaseClient<Database>;
  user?: User;
  waitlistedUser?: User;
  env?: ReturnType<typeof getBrowserEnv>;
};

export function useSupabase() {
  const { supabase } = useOutletContext<ContextType>();
  return supabase;
}

export function useUser(includeWaitlisted = false) {
  const { user, waitlistedUser } = useOutletContext<ContextType>();
  return user ?? (includeWaitlisted ? waitlistedUser : null);
}

export function useEnv() {
  const { env } = useOutletContext<ContextType>();
  return env;
}

export function useTz() {
  const user = useUser();
  const tz = user?.app_metadata?.timezone;
  if (!tz) {
    throw new Error("Missing timezone");
  }
  return tz;
}
