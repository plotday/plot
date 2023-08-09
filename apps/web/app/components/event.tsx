import {
  Anchor,
  Box,
  Button,
  Card,
  Group,
  Stack,
  Text,
  Title,
} from "@mantine/core";
import { useRevalidator } from "@remix-run/react";
import { IconExternalLink } from "@tabler/icons-react";
import { useEffect } from "react";

import { toDate } from "@plotday/tz";

import type { Database, SupabaseClient } from "../db";
import { safeQuery } from "../db";
import { useSupabase } from "../root";

type DbEvent = Database["public"]["Tables"]["event"]["Row"];

export async function getEvents(
  supabase: SupabaseClient,
  from: Date,
  forward: boolean = true
) {
  let during;
  if (forward) {
    during = `[${from.toISOString()}, infinity)`;
  } else {
    during = `(-infinity, ${from.toISOString()}]`;
  }

  return safeQuery(
    await supabase
      .from("event")
      .select()
      .overlaps("at", during)
      .neq("status", "cancelled")
      .order("at", { ascending: forward })
  );
}

export function Events({ events }: { events: DbEvent[] }) {
  const supabase = useSupabase();
  const revalidator = useRevalidator();
  useEffect(() => {
    if (!supabase) return;
    const channel = supabase
      .channel("table-db-changes")
      .on(
        "postgres_changes",
        {
          event: "*",
          schema: "public",
          table: "event",
        },
        (_payload) => {
          revalidator.revalidate();
        }
      )
      .subscribe();
    return () => {
      channel.unsubscribe();
    };
  }, [supabase, revalidator]);

  return (
    <Stack>
      {events.map((event) => (
        <Event key={event.id} event={event} />
      ))}
    </Stack>
  );
}

const USER_TZ = "America/New_York";

export default function Event({ event }: { event: DbEvent }) {
  const dates = ((event.at as string) || "")
    .replaceAll(/["[\]()]/g, "")
    .split(",");
  const start = toDate(dates[0], USER_TZ);
  const end = toDate(dates[1], USER_TZ);
  return (
    <Card>
      <Title order={3}>
        {event.name}{" "}
        {event.provider_link && (
          <Anchor target="_blank" href={event.provider_link}>
            <IconExternalLink />
          </Anchor>
        )}
      </Title>
      <Text>
        {start.toISOString()} - {end.toISOString()}
      </Text>
      {event.conferencing_url && (
        <Group>
          <Button
            component="a"
            target="_blank"
            href={event.conferencing_url}
            fullWidth={false}
          >
            Join
          </Button>
        </Group>
      )}
      {event.description && (
        <Box dangerouslySetInnerHTML={{ __html: event.description }} />
      )}
    </Card>
  );
}
