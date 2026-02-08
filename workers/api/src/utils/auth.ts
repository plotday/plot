import { type SupabaseClient } from "@plotday/db";

export async function getUser(supabase: SupabaseClient, token?: string) {
  // When a token is provided, use getClaims for fast local JWT validation
  if (token) {
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

  // Without a token, use getUser() which reads from the client's global
  // Authorization header (set when creating the client with the user's JWT)
  const { data, error } = await supabase.auth.getUser();
  if (error) {
    return { user: null, error };
  }
  return { user: data.user, error: null };
}
