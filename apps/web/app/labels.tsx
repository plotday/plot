import type { LabelMap } from "@plotday/db/event";

import type { SupabaseClient } from "app/db";
import { safeQuery } from "app/db";

export async function getLabels(supabase: SupabaseClient, _userId: number) {
  return (
    safeQuery(
      await supabase.from("label").select("id,tag,name,description,order")
    ) || []
  ).reduce((acc, cur) => {
    const { id, ...rest } = cur;
    acc[id] = {
      id,
      ...rest,
    };
    return acc;
  }, {} as LabelMap);
}
