import { useOutletContext } from "@remix-run/react";

import type { SupabaseClient } from "@supabase/auth-helpers-remix";

import type { Database } from "@plotday/db";

type Nullable<T> = { [K in keyof T]: T[K] | null };
export type ContextType = {
  supabase?: SupabaseClient<Database>;
  user?: Nullable<Partial<Database["public"]["Tables"]["user"]["Row"]>>;
  waitlistedUser?: Nullable<
    Partial<Database["public"]["Tables"]["user"]["Row"]>
  >;
};

export function useSupabase() {
  const { supabase } = useOutletContext<ContextType>();
  return supabase;
}

export function useUser(includeWaitlisted = false) {
  const { user, waitlistedUser } = useOutletContext<ContextType>();
  return user ?? (includeWaitlisted ? waitlistedUser : null);
}

export function useTz() {
  const user = useUser();
  const tz = user?.timezone;
  if (!tz) {
    throw new Error("Missing timezone");
  }
  return tz;
}
