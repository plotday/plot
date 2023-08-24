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

type Target = {
  target: number | null;
  org: boolean;
};

type TargetUpdate = {
  [labelId: number]: Target;
};

async function getStats(
  supabase: SupabaseClient,
  statFn: "label_stats" | "org_stats",
  userId: number,
  start: Date,
  end: Date
) {
  const during = `[${start.toISOString()}, ${end.toISOString()})`;
  return (
    safeQuery(
      await supabase.rpc(statFn, {
        user_id: userId,
        during,
      })
    ) || []
  ).reduce((acc, cur) => {
    const { response, label_id, event_count, minutes, ...rest } = cur;
    acc[label_id] = {
      ...acc[label_id],
      id: label_id,
      ...rest,
      [response]: { event_count, minutes },
    } as LabelStats;
    return acc;
  }, {} as LabelStatsMap);
}

async function getTargets(supabase: SupabaseClient, userId: number) {
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

export const loader = async ({ context, request }: LoaderArgs) => {
  const { response, supabase } = createServerClient(request, context);
  let user = await getUser(supabase);
  if (!user?.id) throw redirect("/login");

  const tz = user.timezone || "America/New_York";
  const params = new URL(request.url).searchParams;
  const startParam = params.get("month");
  let start;
  if (startParam) {
    start = add(new Date(startParam), { days: 7 });
  } else {
    start = new Date();
  }
  start = startOfMonth(start, tz);
  const end = add(start, { months: 1 });
  const prevStart = sub(start, { months: 1 });

  return typedjson(
    {
      ...(await promiseHash({
        stats: getStats(supabase, "label_stats", user.id, start, end),
        previousStats: getStats(
          supabase,
          "label_stats",
          user.id,
          prevStart,
          start
        ),
        orgStats: getStats(supabase, "org_stats", user.id, start, end),
        previousOrgStats: getStats(
          supabase,
          "org_stats",
          user.id,
          prevStart,
          start
        ),
        targets: getTargets(supabase, user.id),
      })),
      start,
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
  const { stats, previousStats, orgStats, previousOrgStats, start, targets } =
    useTypedLoaderData<typeof loader>();
  useEventWatch(start, add(start, { months: 1 }));

  const user = useUser();
  const tz = user?.timezone || "America/New_York";
  const month = formatDate(start, tz, "MMMM yyyy");
  const defaultStart = startOfMonth(new Date(), tz);
  const monthlyWorkingMinutes =
    differenceInBusinessDays(add(start, { months: 1 }), start) * 8 * 60;
  const previousMonthlyWorkingMinutes =
    differenceInBusinessDays(start, sub(start, { months: 1 })) * 8 * 60;

  const move = (movement: number) => {
    const newStart = add(start, { months: movement });
    setSearchParams((p) => {
      const { month: _month, ...other } = Object.fromEntries(p.entries());
      if (newStart.getTime() === defaultStart.getTime()) return other;
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
            {month}
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
          labelStats={stats}
          previousStats={previousStats}
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
          labelStats={orgStats}
          previousStats={previousOrgStats}
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
