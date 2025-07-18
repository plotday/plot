import {
  type Database,
  type SupabaseClient,
  getCredentials,
  safeQuery,
} from "@plotday/db";

export async function create(
    supabase: SupabaseClient, 
    activity: Database["public"]["Tables"]["activity"]["Insert"]
) {
  if (!activity) {
    return new Response("Bad request (missing activity)", { status: 400 });
  }


  return safeQuery(
    await supabase.from("activity").insert(activity).select().single()
  );
}

export async function update(
  supabase: SupabaseClient,
  activityId: string,
  activity: Database["public"]["Tables"]["activity"]["Update"]
) {
  return safeQuery(
    await supabase
      .from("activity")
      .update(activity)
      .eq("id", activityId)
      .select()
      .single()
  );
}