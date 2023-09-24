import { formatDate } from "@plotday/tz";

import type { LabelStats, LabelStatsMap } from "app/components/tuner";
import type { SupabaseClient } from "app/db";
import { safeQuery } from "app/db";

export type DailyLabelStats = {
  [day: string]: LabelStatsMap;
};

export async function getTargets(supabase: SupabaseClient, userId: number) {
  return (
    safeQuery(
      await supabase.from("target").select("*").eq("user_id", userId)
    ) || []
  ).reduce(
    (acc, cur) => {
      const { label_id, target, org } = cur;
      if (org) {
        acc.orgTargets[label_id] = target;
      } else {
        acc.targets[label_id] = target;
      }
      return acc;
    },
    { targets: {}, orgTargets: {} } as {
      targets: Record<number, number>;
      orgTargets: Record<number, number>;
    }
  );
}

export async function getExpenditures(
  supabase: SupabaseClient,
  userId: number,
  tz: string,
  start: Date,
  end: Date
) {
  return (
    safeQuery(
      await supabase
        .from("expenditure_rolling")
        .select("*")
        .eq("user_id", userId)
        .gte("day", formatDate(start, tz, "yyyy-MM-dd"))
        .lte("day", formatDate(end, tz, "yyyy-MM-dd"))
    ) || []
  ).reduce((acc, cur) => {
    let {
      user_id: _user_id,
      day,
      attendance,
      label_id,
      event_count,
      minutes,
      org_event_count,
      org_minutes,
      ...rest
    } = cur;
    if (!day || !label_id) return acc;
    acc[day] ??= {};
    acc[day][label_id] = {
      ...acc[day][label_id],
      id: label_id,
      ...rest,
      [attendance ?? "pending"]: {
        event_count,
        minutes,
        org_minutes,
        org_event_count,
      },
    } as LabelStats;
    return acc;
  }, {} as DailyLabelStats);
}
