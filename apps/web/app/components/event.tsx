import { useCallback, useEffect, useState } from "react";

import { useRevalidator } from "@remix-run/react";

import {
  Anchor,
  Box,
  Button,
  Card,
  Group,
  Pill,
  SegmentedControl,
  Stack,
  Text,
  Title,
} from "@mantine/core";

import { IconExternalLink } from "@tabler/icons-react";

import { formatDay, formatTimes, toDate } from "@plotday/tz";

import type { Database, SupabaseClient } from "app/db";
import { safeQuery } from "app/db";
import { useSupabase } from "app/root";

type EventResponse = Database["public"]["Enums"]["event_response"];
type DbEvents = Awaited<ReturnType<typeof getEvents>>;
type Flatten<Type> = Type extends Array<infer Item> ? Item : Type;
type DbEvent = Flatten<DbEvents>;

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

  const events = safeQuery(
    await supabase
      .from("event")
      .select(
        "*,invitees:invitee(response,is_optional,contact(id,name,email,contact_user_id))"
      )
      .overlaps("at", during)
      .neq("status", "cancelled")
      .order("at", { ascending: forward })
      .limit(100)
  );
  if (!events) return [];

  // Add responses (probably convert this to a view)
  return events
    .filter((e) => !!e)
    .map((event) => ({
      ...event,
      response:
        // This assume contact_user_id is only set for the owner
        event.invitees.find((invitee) => !!invitee.contact?.contact_user_id)
          ?.response || null,
    }));
}

export function Events({ events, tz }: { events: DbEvent[]; tz: string }) {
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
        <Event key={event.id} event={event} tz={tz} />
      ))}
    </Stack>
  );
}

export default function Event({ event, tz }: { event: DbEvent; tz: string }) {
  const [response, setResponseState] = useState(event.response || undefined);
  const setResponse = useCallback((response?: string) => {
    console.log(response);
    setResponseState(response as EventResponse);
  }, []);
  const dates = ((event.at as string) || "")
    .replaceAll(/["[\]()]/g, "")
    .split(",");
  const start = toDate(dates[0], tz);
  const end = toDate(dates[1], tz);
  return (
    <Card withBorder>
      <Stack>
        <Title order={3}>
          {event.name}{" "}
          {event.provider_link && (
            <Anchor target="_blank" href={event.provider_link}>
              <IconExternalLink />
            </Anchor>
          )}
        </Title>
        <Text>
          {formatDay(start, tz)}, {formatTimes(start, end, tz)}
        </Text>
        <Box>
          <SegmentedControl
            value={response}
            onChange={setResponse}
            data={[
              { label: "Skip", value: "declined" },
              { label: "Action", value: "tentative" },
              { label: "Go", value: "accepted" },
            ]}
          />
        </Box>
        {event.invitees.length > 1 && (
          <Text>
            {event.invitees.map((invitee) => (
              <Pill key={invitee.contact?.id}>
                {invitee.contact?.name || invitee.contact?.email}
              </Pill>
            ))}
          </Text>
        )}
        {event.description && (
          <Box dangerouslySetInnerHTML={{ __html: event.description }} />
        )}
        {event.conferencing_url && (
          <Group>
            <Button
              variant="light"
              component="a"
              target="_blank"
              href={event.conferencing_url}
              fullWidth={false}
            >
              Join
            </Button>
          </Group>
        )}
      </Stack>
    </Card>
  );
}
