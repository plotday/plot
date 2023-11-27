import add from "date-fns/add";

import { formatDate } from "@plotday/tz";

import type { Database, SupabaseClient } from "./";
import { parseDateRange, safeQuery } from "./";

export type Insights = {
  [event_type in Database["public"]["Enums"]["event_type"]]: {
    [response in Database["public"]["Enums"]["event_response"]]: {
      [name: string]: {
        [value: string]: {
          minutes: number;
          count: number;
        };
      };
    };
  };
};

export type Balance = {
  minutes: number;
  pending_minutes: number;
};

export type Balances = {
  [week: string]: {
    [category_id: number]: Balance;
  };
};

export type DbCategories = NonNullable<
  Awaited<ReturnType<typeof getCategories>>
>;
export type DbCategory = NonNullable<DbCategories[0]>;

export async function getCategory(
  supabase: SupabaseClient,
  userId: number,
  path: string
) {
  const results = safeQuery(
    await supabase
      .from("category")
      .select("*")
      .eq("user_id", userId)
      .eq("path", path)
      .maybeSingle()
  );
  if (!results) throw new Response("Not found", { status: 404 });
  return {
    ...results,
    path: results.path as string,
  };
}

export async function getCategories(supabase: SupabaseClient, userId: number) {
  const results =
    safeQuery(
      await supabase
        .from("category")
        .select("*")
        .eq("user_id", userId)
        .order("priority")
        .order("created_at")
    ) || [];
  return results.map((result) => ({
    ...result,
    path: result.path as string,
  }));
}

export async function getGoals(
  supabase: SupabaseClient,
  userId: number,
  start?: Date,
  end?: Date
) {
  return (
    safeQuery(await supabase.from("goal").select("*").eq("user_id", userId)) ||
    []
  ).reduce((acc, cur) => {
    const { category_id, at, type, weekly_minutes, minimize } = cur;
    acc[category_id] = {
      ...acc[category_id],
      [type]: {
        // TODO: start and end
        weekly_minutes,
        minimize,
      },
    };
    return acc;
  }, {} as Record<number, Record<string, { start?: Date; end?: Date; weekly_minutes: number; minimize: boolean }>>);
}

export async function getCategoryInsights(
  supabase: SupabaseClient,
  userId: number,
  category: string,
  start: string,
  end?: string
) {
  if (!end) {
    end = formatDate(add(new Date(start), { days: 7 }), "UTC", "yyyy-MM-dd");
  }
  const weeklyTotals = safeQuery(
    await supabase
      .from("insight_weekly")
      .select(
        "week, type, count, minutes, pending_count, pending_minutes, name, value"
      )
      .eq("user_id", userId)
      .eq("path", category)
      .overlaps("week", `[${start},${end})`)
  );
  if (!weeklyTotals) return null;

  return weeklyTotals.reduce(
    (acc, cur) => {
      let { week, type, name, value, ...rest } = cur;
      if (!week || !type) return acc;
      const weekKey = parseDateRange(week as string)[0];
      acc[weekKey] = {
        ...acc[weekKey],
        [type]: {
          ...acc?.[weekKey]?.[type],
          ...(name
            ? {
                [name]: [
                  ...(acc[weekKey]?.[type]?.[name] ?? []),
                  {
                    ...rest,
                    ...(value ? { value } : {}),
                  },
                ],
              }
            : {}),
        },
      };
      return acc;
    },

    {} as {
      [week: string]: {
        [type in Database["public"]["Enums"]["event_type"]]: {
          [name: string]: {
            count: number;
            minutes: number;
            pending_count: number;
            pending_minutes: number;
            value: string;
          }[];
        };
      };
    }
  );
}

export async function getCategoriesWithTotals(
  supabase: SupabaseClient,
  userId: number,
  start: string,
  end?: string
) {
  if (!end) {
    end = formatDate(add(new Date(start), { days: 7 }), "UTC", "yyyy-MM-dd");
  }
  const [categories, weeklyTotals] = await Promise.all([
    getCategories(supabase, userId),
    safeQuery(
      supabase
        .from("insight_weekly")
        .select()
        .eq("user_id", userId)
        .eq("name", "Total")
        .overlaps("week", `[${start},${end})`)
    ),
  ]);
  if (!categories || !weeklyTotals) return null;

  return weeklyTotals.reduce(
    (acc, cur) => {
      let { week, path: rawPath, type, ...rest } = cur;
      if (!week || !rawPath || !type) return acc;
      const path = rawPath as string;
      const weekKey = parseDateRange(week as string)[0];
      acc[path] = {
        ...acc[path],
        insights: {
          [weekKey]: {
            ...acc[path].insights[weekKey],
            [type]: rest,
          },
        },
      };
      return acc;
    },
    categories.reduce(
      (acc, cur) => {
        const { path, ...rest } = cur;
        return {
          ...acc,
          [path]: { ...rest, path: path as string, insights: {} },
        };
      },
      {} as Record<
        string,
        (typeof categories)[0] & {
          path: string;
          insights: {
            [week: string]: {
              [type in Database["public"]["Enums"]["event_type"]]: {
                minutes: number;
                count: number;
              };
            };
          };
        }
      >
    )
  );
}
