import { type SupabaseClient } from "@plotday/db";

export async function getUser(supabase: SupabaseClient, token?: string) {
  const { data, error } = await supabase.auth.getClaims(token);
  if (error) {
    return { user: null, error };
  }
  const user = data?.claims
    ? {
        ...data?.claims,
        id: data.claims.sub,
        email: data.claims.email,
      }
    : null;
  return { user, error: null };
}
