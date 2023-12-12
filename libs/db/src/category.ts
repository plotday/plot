import add from "date-fns/add";

import { formatDate } from "@plotday/tz";

import type { Database, SupabaseClient } from "./";
import { parseDateRange, safeQuery } from "./";

export type Category = Omit<
  Database["public"]["Tables"]["category"]["Row"],
  "path"
> & {
  path: string;
  totals?: {
    [week: string]: {
      [type in Database["public"]["Enums"]["event_type"]]?: {
        minutes: number;
        count: number;
      };
    };
  };
  budgets?: {
    [week: string]: {
      budget?: number;
      order?: string;
    };
  };
};

export type Categories = {
  [path: string]: Category;
};

export type CategoryWeek = Omit<Category, "totals" | "budgets"> & {
  budget?: number;
  order?: string;
  totals?: {
    [type in Database["public"]["Enums"]["event_type"]]?: {
      minutes: number;
      count: number;
    };
  };
};

export type CategoriesWeek = CategoryWeek[];

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

export async function getCategories(
  supabase: SupabaseClient,
  userId: number,
  start?: string,
  end?: string
): Promise<Categories> {
  if (start && !end) {
    end = formatDate(add(new Date(start), { days: 7 }), "UTC", "yyyy-MM-dd");
  }
  const [categories, weeklyTotals] = await Promise.all([
    safeQuery(
      await supabase
        .from("category")
        .select("*,budget(*)")
        // TODO: filter by date
        .eq("user_id", userId)
    ),
    start &&
      safeQuery(
        supabase
          .from("insight_weekly")
          .select()
          .eq("user_id", userId)
          .eq("name", "Total")
          .overlaps("week", `[${start},${end})`)
      ),
  ]);
  if (!categories) return {};

  const groupedCategories = Object.fromEntries(
    categories.map((r) => {
      const { path, budget, ...rest } = r;
      return [
        path as string,
        {
          ...rest,
          path: path as string,
          budgets: budget.reduce((acc, cur) => {
            const { week, budget, order } = cur;
            acc[week ? parseDateRange(week as string)[0] : "*"] = {
              budget: budget ?? undefined,
              order: order ?? undefined,
            };
            return acc;
          }, {} as Record<string, { budget?: number; order?: string }>),
        },
      ];
    })
  );
  if (!weeklyTotals) return groupedCategories;
  return weeklyTotals.reduce<Categories>((acc, cur) => {
    let { week, path: rawPath, type, ...rest } = cur;
    if (!week || !rawPath || !type) return acc;
    const path = rawPath as string;
    const weekKey = parseDateRange(week as string)[0];
    acc[path] = {
      ...acc[path],
      totals: {
        [weekKey]: {
          ...acc[path].totals?.[weekKey],
          [type]: rest,
        },
      },
    };
    return acc;
  }, groupedCategories);
}

export async function getCategoriesWeek(
  supabase: SupabaseClient,
  userId: number,
  week: string
): Promise<CategoriesWeek> {
  const categories = await getCategories(supabase, userId, week);

  return Object.entries(categories)
    .map(
      ([, { budgets, totals, ...rest }]: [string, Category]): CategoryWeek => {
        return {
          ...rest,
          budget: (budgets?.[week] ?? budgets?.["*"])?.budget,
          order: budgets?.[week]?.order,
          totals: totals?.[week],
        };
      }
    )
    .sort((a, b) => (!b.order || (a.order && a.order < b.order) ? -1 : 1));
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
