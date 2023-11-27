import { useMemo } from "react";

import { redirect } from "@remix-run/cloudflare";

import { Card, Center, SimpleGrid, Stack, Title } from "@mantine/core";

import { typedjson, useTypedLoaderData } from "remix-typedjson";
import { promiseHash } from "remix-utils/promise";
import { z } from "zod";

import {
  Event,
  getCategories,
  getCategory,
  getCategoryInsights,
  nameToPath,
  pathToUrl,
  safeQuery,
  urlToPath,
} from "@plotday/db";

import { EventCard } from "app/components/event";
import { Gauge } from "app/components/gauge";
import { getWeek } from "app/components/select-week";
import { WeeklyGoal } from "app/components/weekly-goal";
import { useTz } from "app/hooks";
import { privateAction, privateLoader } from "app/util";

export const loader = privateLoader(
  async ({ params, url, response, user, supabase }) => {
    const { week, start, end } = getWeek(url.searchParams, user.timezone);

    let role = params.role && urlToPath(params.role.slice(1));
    let category = params.category && urlToPath(params.category);
    if (!role || !category) throw new Response("Not found", { status: 404 });
    let path;
    if (category === "other") {
      path = role;
    } else {
      path = `${role}.${category}`;
    }
    return typedjson(
      {
        ...(await promiseHash({
          category: getCategory(supabase, user.id, path),
          insights: getCategoryInsights(supabase, user.id, path, week),
          categories: getCategories(supabase, user.id),
          events: Event.GetRange(supabase, user.id, start, end, {
            category: path,
          }),
        })),
        week,
      },
      { headers: response.headers }
    );
  }
);

export const action = privateAction(
  async ({ request, params, user, supabase }) => {
    const role = params.role && urlToPath(params.role.slice(1));
    let category = params.category && urlToPath(params.category);
    let path;
    if (category && category !== "other") {
      path = `${role}.${category}`;
    } else {
      path = role as string;
    }

    switch (request.method) {
      case "POST": {
        const schema = z.object({
          name: z.string(),
          priority: z.string().optional(),
          "no-redirect": z.string().optional(),
        });
        const data = schema.parse(Object.fromEntries(await request.formData()));
        const category = nameToPath(data.name);
        const path = `${role}.${category}`;
        const priority = data.priority ?? "O";
        safeQuery(
          await supabase
            .from("category")
            .insert({ user_id: user.id, name: data.name, path, priority })
        );
        if (data["no-redirect"]) {
          return null;
        } else {
          return redirect(pathToUrl(path));
        }
      }

      case "PATCH": {
        const schema = z.object({
          name: z.string().optional(),
          minimize: z
            .enum(["true", "false"])
            .transform((value) => value === "true")
            .optional(),
          budget_weekly: z.coerce.number().optional(),
          balance_weekly_grant: z.coerce.number().optional(),
          priority: z.string().optional(),
        });
        const data = schema.parse(Object.fromEntries(await request.formData()));
        let url: string | undefined = undefined;
        let nameUpdate = {};
        if (data.name) {
          const category = nameToPath(data.name);
          const path = `${role}.${category}`;
          nameUpdate = { name: data.name, path };
          url = pathToUrl(path);
        }
        safeQuery(
          await supabase
            .from("category")
            .update({
              ...nameUpdate,
              ...(data.minimize !== undefined
                ? { minimize: data.minimize }
                : {}),
              ...(data.budget_weekly !== undefined
                ? { budget_weekly: data.budget_weekly }
                : {}),
              ...(data.balance_weekly_grant !== undefined
                ? { balance_weekly_grant: data.balance_weekly_grant }
                : {}),
              ...(data.priority !== undefined
                ? { priority: data.priority }
                : {}),
            })
            .eq("user_id", user.id)
            .eq("path", path)
        );
        if (url) {
          return redirect(url);
        }
        return null;
      }

      case "DELETE": {
        safeQuery(
          await supabase
            .from("category")
            .delete()
            .eq("user_id", user.id)
            .eq("path", path)
        );
        return redirect(`/${params.role}`);
      }

      default:
        return new Response("Unsupported method", { status: 405 });
    }
  }
);

export default function Category() {
  const {
    category,
    categories,
    events: dbEvents,
    insights,
    week,
  } = useTypedLoaderData<typeof loader>();
  const tz = useTz();
  const events = useMemo(
    () => dbEvents?.map?.((e) => new Event(e, tz)),
    [dbEvents, tz]
  );
  const minimize = category?.minimize ?? false;

  if (!category || !week) return null;
  const totals = insights?.[week]
    ? Object.fromEntries(
        Object.entries(insights[week]).map(([type, values]) => [
          type,
          values.Total[0],
        ])
      )
    : {};

  const totalTime = Math.max(
    (totals?.meeting?.minutes ?? 0) + (totals?.task?.minutes ?? 0),
    category.budget_weekly ?? 0
  );

  return (
    <SimpleGrid cols={{ base: 1, md: 2 }} spacing="md">
      <Stack>
        <Title order={3}>Your Time</Title>
        <Card>
          <WeeklyGoal category={category} insights={totals} />
        </Card>
        {categories &&
          events?.map((event) => (
            <EventCard
              key={event.id}
              event={event}
              minimize={minimize}
              categories={categories}
              totalTime={totalTime}
            />
          ))}
      </Stack>
      <Card>
        <Stack>
          <Title order={3}>Meeting Insights</Title>
          <SimpleGrid cols={{ base: 2, sm: 3 }}>
            {Object.entries(insights?.[week]?.meeting ?? {})
              .filter(([key]) => key !== "Total")
              .map(([key, values]) => (
                <Center key={key}>
                  <Gauge label={key} values={values} />
                </Center>
              ))}
          </SimpleGrid>
        </Stack>
      </Card>
    </SimpleGrid>
  );
}
