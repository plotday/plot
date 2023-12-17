import { useLoaderData, useOutletContext } from "@remix-run/react";

import type { SupabaseClient } from "@supabase/supabase-js";

import type { Database } from "@plotday/db";

import type { getBrowserEnv } from "./env.server";

type Nullable<T> = { [K in keyof T]: T[K] | null };
export type ContextType = {
  supabase?: SupabaseClient<Database>;
  user?: Nullable<Partial<Database["public"]["Tables"]["user"]["Row"]>>;
  waitlistedUser?: Nullable<
    Partial<Database["public"]["Tables"]["user"]["Row"]>
  >;
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
  const tz = user?.timezone;
  if (!tz) {
    throw new Error("Missing timezone");
  }
  return tz;
}
