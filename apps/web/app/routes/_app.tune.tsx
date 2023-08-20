import type { LoaderArgs } from "@remix-run/cloudflare";
import { redirect } from "@remix-run/cloudflare";
import { useSearchParams } from "@remix-run/react";

import { Button, Card, Center, Group, Stack, Text } from "@mantine/core";

import { IconChevronLeft, IconChevronRight } from "@tabler/icons-react";
import add from "date-fns/add";
import sub from "date-fns/sub";
import { typedjson, useTypedLoaderData } from "remix-typedjson";

import { formatDate, startOfMonth } from "@plotday/tz";

import { getUser } from "app/auth";
import type { LabelStats } from "app/components/tuner";
import { TunerList } from "app/components/tuner";
import type { SupabaseClient } from "app/db";
import { createServerClient, safeQuery } from "app/db";
import { useEventWatch } from "app/event";
import { useUser } from "app/root";

async function getStats(
  supabase: SupabaseClient,
  userId: number,
  start: Date,
  end: Date
) {
  const during = `[${start.toISOString()}, ${end.toISOString()})`;
  return (
    safeQuery(
      await supabase.rpc("label_stats", {
        user_id: userId,
        during,
      })
    ) || []
  ).reduce((acc, cur) => {
    const { name, description, response, label_id, ...rest } = cur;
    acc[label_id] ??= {} as LabelStats;
    acc[label_id].id = label_id;
    acc[label_id].name = name;
    acc[label_id].description = description;
    acc[label_id][response] = rest;
    return acc;
  }, {} as Record<string, LabelStats>);
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

  const stats = await getStats(supabase, user.id, start, end);
  const previousStats = await getStats(supabase, user.id, prevStart, start);

  return typedjson(
    {
      stats,
      previousStats,
      start,
    },
    { headers: response.headers }
  );
};

export default function Prep() {
  const [, setSearchParams] = useSearchParams();
  const { stats, previousStats, start } = useTypedLoaderData<typeof loader>();
  useEventWatch(start, add(start, { months: 1 }));

  const user = useUser();
  const tz = user?.timezone || "America/New_York";
  const month = formatDate(start, tz, "MMMM yyyy");
  const defaultStart = startOfMonth(new Date(), tz);

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
        <TunerList
          labelStats={stats}
          previousStats={previousStats}
          workingMinutes={4.2 * 5 * 40 * 60}
          previousWorkingMinutes={4.2 * 5 * 40 * 60}
        />
      </Card>
    </Stack>
  );
}
