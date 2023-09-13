import type { ActionArgs, LoaderArgs } from "@remix-run/cloudflare";
import { json, redirect } from "@remix-run/cloudflare";
import { useFetcher, useSearchParams } from "@remix-run/react";

import {
  Button,
  Card,
  Center,
  Group,
  Stack,
  Text,
  Title,
  Tooltip,
} from "@mantine/core";

import { IconChevronLeft, IconChevronRight } from "@tabler/icons-react";
import add from "date-fns/add";
import differenceInBusinessDays from "date-fns/differenceInBusinessDays";
import sub from "date-fns/sub";
import { typedjson, useTypedLoaderData } from "remix-typedjson";
import { promiseHash } from "remix-utils";

import { formatDate, startOfMonth } from "@plotday/tz";

import { getUser } from "app/auth";
import type { LabelStats, LabelStatsMap } from "app/components/tuner";
import { TunerList } from "app/components/tuner";
import type { SupabaseClient } from "app/db";
import { createServerClient, safeQuery } from "app/db";
import { useEventWatch } from "app/event";
import { useUser } from "app/hooks";
import { getTargets } from "app/target";

type Target = {
  target: number | null;
  org: boolean;
};

type TargetUpdate = {
  [labelId: number]: Target;
};

type MonthlyLabelStats = {
  [month: string]: LabelStatsMap;
};

async function getStats(
  supabase: SupabaseClient,
  userId: number,
  tz: string,
  months: Date[]
) {
  const dates = months.map((month) => formatDate(month, tz, "yyyy-MM-01"));
  return (
    safeQuery(
      await supabase
        .from("expenditure_monthly")
        .select("*,label(tag,name)")
        .eq("user_id", userId)
        .in("month", dates)
    ) || []
  ).reduce((acc, cur) => {
    let {
      user_id: _user_id,
      month,
      response,
      label_id,
      label,
      event_count,
      minutes,
      org_event_count,
      org_minutes,
      ...rest
    } = cur;
    if (!month || !label_id || !response) return acc;
    month = month.replace("-01", "");
    acc[month] ??= {};
    acc[month][label_id] = {
      ...acc[month][label_id],
      id: label_id,
      ...label,
      ...rest,
      [response]: { event_count, minutes, org_minutes, org_event_count },
    } as LabelStats;
    return acc;
  }, {} as MonthlyLabelStats);
}

export const loader = async ({ context, request }: LoaderArgs) => {
  const { response, supabase } = createServerClient(request, context);
  let user = await getUser(supabase);
  if (!user?.id) throw redirect("/login");

  const tz = user.timezone || "America/New_York";
  const params = new URL(request.url).searchParams;
  const startParam = params.get("month");
  let month;
  if (startParam) {
    month = add(new Date(startParam), { days: 7 });
  } else {
    month = new Date();
  }
  month = startOfMonth(month, tz);
  const previousMonth = sub(month, { months: 1 });

  return typedjson(
    {
      ...(await promiseHash({
        stats: getStats(supabase, user.id, tz, [previousMonth, month]),
        targets: getTargets(supabase, user.id),
      })),
      month,
      previousMonth,
    },
    { headers: response.headers }
  );
};

export async function action({ context, request }: ActionArgs) {
  const { supabase } = createServerClient(request, context);
  let user = await getUser(supabase);
  if (!user?.id) throw redirect("/login");
  const bodyParams = await request.formData();
  if (typeof bodyParams.get("targets") === "string") {
    const targets = JSON.parse(
      bodyParams.get("targets") as string
    ) as TargetUpdate;
    for (const [labelId, target] of Object.entries(targets)) {
      if (target.target !== null) {
        safeQuery(
          await supabase.from("target").upsert({
            user_id: user.id,
            label_id: parseInt(labelId),
            target: target.target,
            org: target.org,
          })
        );
      } else {
        safeQuery(
          await supabase
            .from("target")
            .delete()
            .eq("user_id", user.id)
            .eq("label_id", parseInt(labelId))
            .eq("org", target.org)
        );
      }
    }
  }
  return json({});
}

export default function Tune() {
  const fetcher = useFetcher();

  const [, setSearchParams] = useSearchParams();
  const { stats, month, previousMonth, targets } =
    useTypedLoaderData<typeof loader>();
  useEventWatch(month, add(month, { months: 1 }));

  const user = useUser();
  const tz = user?.timezone || "America/New_York";
  const monthTitle = formatDate(month, tz, "MMMM yyyy");
  const defaultMonth = startOfMonth(new Date(), tz);
  const monthlyWorkingMinutes =
    differenceInBusinessDays(add(month, { months: 1 }), month) * 8 * 60;
  const previousMonthlyWorkingMinutes =
    differenceInBusinessDays(month, sub(month, { months: 1 })) * 8 * 60;

  const monthKey = formatDate(month, tz, "yyyy-MM");
  const previousMonthKey = formatDate(previousMonth, tz, "yyyy-MM");

  const move = (movement: number) => {
    const newStart = add(month, { months: movement });
    setSearchParams((p) => {
      const { month: _month, ...other } = Object.fromEntries(p.entries());
      if (newStart.getTime() === defaultMonth.getTime()) return other;
      return {
        ...other,
        month: formatDate(newStart, tz, "yyyy-MM"),
      };
    });
  };

  const onTargetChange = (
    labelId: number,
    target: number | null,
    org: boolean
  ) => {
    const body: TargetUpdate = {
      [labelId]: {
        target,
        org,
      },
    };
    fetcher.submit(
      {
        targets: JSON.stringify(body),
      },
      { method: "put" }
    );
  };

  return (
    <Stack>
      <Center>
        <Group gap={0}>
          <Button
            variant="subtle"
            onClick={() => {
              move(-1);
            }}
          >
            <IconChevronLeft />
          </Button>
          <Text w="8em" ta="center">
            {monthTitle}
          </Text>
          <Button
            variant="subtle"
            onClick={() => {
              move(1);
            }}
          >
            <IconChevronRight />
          </Button>
        </Group>
      </Center>
      <Card>
        <Title order={2} mb="md">
          <Tooltip label="This is the personal impact of meeting on your time">
            <Text span inherit>
              Meeting load
            </Text>
          </Tooltip>
        </Title>
        <TunerList
          labelStats={stats[monthKey]}
          previousStats={stats[previousMonthKey]}
          monthlyWorkingMinutes={monthlyWorkingMinutes}
          previousMonthlyWorkingMinutes={previousMonthlyWorkingMinutes}
          weeklyWorkingMinutes={40 * 60}
          targets={targets.targets}
          onTargetChange={onTargetChange}
          org={false}
        />
      </Card>
      <Card mt="xl">
        <Title order={2} mb="md">
          <Tooltip label="This is the amount of meeting load the meetings you initiate have on the organization">
            <Text span inherit>
              Organizational impact
            </Text>
          </Tooltip>
        </Title>
        <TunerList
          labelStats={stats[monthKey]}
          previousStats={stats[previousMonthKey]}
          monthlyWorkingMinutes={monthlyWorkingMinutes}
          previousMonthlyWorkingMinutes={previousMonthlyWorkingMinutes}
          weeklyWorkingMinutes={40 * 60}
          targets={targets.orgTargets}
          onTargetChange={onTargetChange}
          org={true}
        />
      </Card>
    </Stack>
  );
}
