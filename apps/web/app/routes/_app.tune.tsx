import { useMemo } from "react";

import { json } from "@remix-run/cloudflare";
import { useFetcher, useSearchParams } from "@remix-run/react";

import {
  Box,
  Button,
  Card,
  Center,
  Group,
  SimpleGrid,
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
import { promiseHash } from "remix-utils/promise";

import { formatDate, startOfMonth } from "@plotday/tz";

import { Gauge } from "app/components/gauge";
import type { LabelStats, LabelStatsMap } from "app/components/tuner";
import { TunerList } from "app/components/tuner";
import type { SupabaseClient } from "app/db";
import { safeQuery } from "app/db";
import { ErrorPage } from "app/error";
import { useEventWatch } from "app/event";
import { useUser } from "app/hooks";
import { getTargets } from "app/target";
import { privateAction, privateLoader } from "app/util";

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

async function getLabelStats(
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
  ).reduce(
    (acc, cur) => {
      let {
        user_id: _user_id,
        month,
        attendance,
        label_id,
        label,
        event_count,
        minutes,
        org_event_count,
        org_minutes,
        ...rest
      } = cur;
      if (!month || !label_id) return acc;
      month = month.replace("-01", "");
      acc[month][label_id] = {
        ...acc[month][label_id],
        id: label_id,
        ...label,
        ...rest,
        [attendance === "attend" || attendance === "skip"
          ? attendance
          : "pending"]: { event_count, minutes, org_minutes, org_event_count },
      } as LabelStats;
      return acc;
    },
    dates.reduce((acc, month) => {
      acc[month.replace("-01", "")] = {};
      return acc;
    }, {} as MonthlyLabelStats)
  );
}

async function getGapStats(
  supabase: SupabaseClient,
  userId: number,
  tz: string,
  months: Date[]
) {
  const dates = months.map((month) => formatDate(month, tz, "yyyy-MM-01"));
  const gap =
    safeQuery(
      await supabase
        .from("gap_monthly")
        .select("*")
        .eq("user_id", userId)
        .in("month", dates)
    ) || [];
  return gap.reduce(
    (acc, cur) => {
      let { month, user_id: _user_id, ...rest } = cur;
      if (!month) return acc;
      month = month.replace("-01", "");
      acc[month] = rest;
      return acc;
    },
    dates.reduce((acc, month) => {
      acc[month.replace("-01", "")] = {
        focus: 0,
        total: 0,
      };
      return acc;
    }, {} as Record<string, Omit<(typeof gap)[number], "month" | "user_id">>)
  );
}

async function getPrepStats(
  supabase: SupabaseClient,
  userId: number,
  tz: string,
  months: Date[]
) {
  const dates = months.map((month) => formatDate(month, tz, "yyyy-MM-01"));
  const prep =
    safeQuery(
      await supabase
        .from("prep_monthly")
        .select("*")
        .eq("user_id", userId)
        .in("month", dates)
    ) || [];
  return prep.reduce(
    (acc, cur) => {
      let { month, user_id: _user_id, ...rest } = cur;
      if (!month) return acc;
      month = month.replace("-01", "");
      acc[month] = rest;
      return acc;
    },
    dates.reduce((acc, month) => {
      acc[month.replace("-01", "")] = {
        past_count: 0,
        past_ready_count: 0,
        past_reviewed_count: 0,
        review_time: 0,
      };
      return acc;
    }, {} as Record<string, Omit<(typeof prep)[number], "month" | "user_id">>)
  );
}

export const loader = privateLoader(
  async ({ request, response, user, supabase }) => {
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
          stats: getLabelStats(supabase, user.id, tz, [previousMonth, month]),
          gaps: getGapStats(supabase, user.id, tz, [previousMonth, month]),
          prep: getPrepStats(supabase, user.id, tz, [previousMonth, month]),
          targets: getTargets(supabase, user.id),
        })),
        month,
        previousMonth,
      },
      { headers: response.headers }
    );
  }
);

export const action = privateAction(
  async ({ request, supabase, user, tracker }) => {
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
          tracker.goalSet(user.id.toString(), {
            Category: labelId,
          });
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
);

export function ErrorBoundary() {
  return <ErrorPage />;
}

function ratio(n?: number | null, total?: number | null) {
  if (!n || !total) return 100;
  return (n / total) * 100;
}

function trend(current?: number | null, previous?: number | null) {
  current ??= 0;
  previous ??= 0;
  if (current && !previous) return 100;
  if (!current && previous) return -100;
  if (!current && !previous) return 0;
  return ((current - previous) / previous) * 100;
}

export default function Tune() {
  const fetcher = useFetcher();

  const [, setSearchParams] = useSearchParams();
  const {
    stats: statsWithMeetings,
    gaps,
    prep,
    month,
    previousMonth,
    targets,
  } = useTypedLoaderData<typeof loader>();
  useEventWatch(month, add(month, { months: 1 }));

  const user = useUser();
  const tz = user?.timezone || "America/New_York";
  const monthTitle = formatDate(month, tz, "MMMM yyyy");
  const defaultMonth = startOfMonth(new Date(), tz);
  const monthlyWorkingMinutes =
    differenceInBusinessDays(add(month, { months: 1 }), month) * 8 * 60;
  const previousMonthlyWorkingMinutes =
    differenceInBusinessDays(month, sub(month, { months: 1 })) * 8 * 60;
  const weeklyWorkingMinutes = 40 * 60;

  const monthKey = formatDate(month, tz, "yyyy-MM");
  const previousMonthKey = formatDate(previousMonth, tz, "yyyy-MM");
  const focus = gaps[monthKey].focus;
  const previousFocus = gaps[previousMonthKey].focus;

  const stats = useMemo(
    () =>
      Object.fromEntries(
        Object.entries(statsWithMeetings).map(([month, stats]) => {
          const { 1: _, ...rest } = stats;
          return [month, rest];
        })
      ),
    [statsWithMeetings]
  );
  const meetings = statsWithMeetings[monthKey][1]?.attend?.minutes ?? 0;
  const previousMeetings =
    statsWithMeetings[previousMonthKey][1]?.attend?.minutes ?? 0;
  const pendingMeetings = statsWithMeetings[monthKey][1]?.pending?.minutes ?? 0;
  const previousPending =
    statsWithMeetings[previousMonthKey][1]?.pending?.minutes ?? 0;

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
    <>
      <Box
        mt="-1rem"
        ml="-1rem"
        mr="-1rem"
        pt="1rem"
        pb="1rem"
        style={{
          position: "sticky",
          top: 0,
          zIndex: 99,
        }}
      >
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
      </Box>
      <Stack gap="xl">
        <Card>
          <SimpleGrid cols={{ base: 1, sm: 2, lg: 4 }}>
            <Gauge
              label="Meetings"
              actual={
                meetings ? (meetings / monthlyWorkingMinutes) * 100 : null
              }
              pending={
                pendingMeetings
                  ? (pendingMeetings / monthlyWorkingMinutes) * 100
                  : undefined
              }
              trend={trend(meetings, previousMeetings)}
              weeklyWorkingMinutes={weeklyWorkingMinutes}
            />
            <Gauge
              label="Focus"
              description="Time during working hours you have an hour or more of uninterrupted time"
              actual={focus ? (focus / monthlyWorkingMinutes) * 100 : null}
              trend={trend(focus, previousFocus)}
              weeklyWorkingMinutes={weeklyWorkingMinutes}
            />
            <Gauge
              label="Prep"
              description="Meetings where you are prepared before the start"
              actual={
                prep[monthKey].past_count
                  ? ((prep[monthKey].past_ready_count ?? 0) /
                      (prep[monthKey].past_count ?? 0)) *
                    100
                  : 0
              }
              trend={trend(
                ratio(
                  prep[monthKey].past_ready_count,
                  prep[monthKey].past_count
                ),
                ratio(
                  prep[previousMonthKey].past_ready_count,
                  prep[previousMonthKey].past_count
                )
              )}
            />
            <Gauge
              label="Review"
              description="Meetings you review within 2 days"
              actual={
                prep[monthKey].past_count
                  ? ((prep[monthKey].past_reviewed_count ?? 0) /
                      (prep[monthKey].past_count ?? 0)) *
                    100
                  : 0
              }
              trend={trend(
                ratio(
                  prep[monthKey].past_reviewed_count,
                  prep[monthKey].past_count
                ),
                ratio(
                  prep[previousMonthKey].past_reviewed_count,
                  prep[previousMonthKey].past_count
                )
              )}
            />
          </SimpleGrid>
        </Card>
        <Card>
          <Title order={2} mb="md">
            <Tooltip label="Time you spend in meetings">
              <Text span inherit>
                Personal meeting load
              </Text>
            </Tooltip>
          </Title>
          <TunerList
            labelStats={stats[monthKey]}
            previousStats={stats[previousMonthKey]}
            monthlyWorkingMinutes={monthlyWorkingMinutes}
            previousMonthlyWorkingMinutes={previousMonthlyWorkingMinutes}
            weeklyWorkingMinutes={weeklyWorkingMinutes}
            targets={targets.targets}
            onTargetChange={onTargetChange}
            org={false}
          />
        </Card>
        <Card>
          <Title order={2} mb="md">
            <Tooltip label="Time the organization spends in meeting that you organize">
              <Text span inherit>
                Organizational meeting load
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
    </>
  );
}
