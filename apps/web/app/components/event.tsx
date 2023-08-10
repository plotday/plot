import React, { useCallback, useEffect, useState } from "react";

import { useRevalidator } from "@remix-run/react";

import {
  Anchor,
  Box,
  Button,
  Card,
  Chip,
  Group,
  Pill,
  Stack,
  Text,
  Title,
} from "@mantine/core";

import { IconExternalLink } from "@tabler/icons-react";

import { formatDay, formatTimes, isSameDay, toDate } from "@plotday/tz";

import type { SupabaseClient } from "app/db";
import { safeQuery } from "app/db";
import { useSupabase } from "app/root";
import { useEventUpdater } from "app/routes/api.event";

type DbEvents = Awaited<ReturnType<typeof getEvents>>;
type Flatten<Type> = Type extends Array<infer Item> ? Item : Type;
type DbEvent = Flatten<DbEvents>;

export class Event {
  public static Hydrate(dbEvents: DbEvent[], tz: string) {
    return dbEvents.map((e: DbEvent) => new Event(e, tz));
  }

  constructor(public dbEvent: DbEvent, public tz: string) {}

  public get id() {
    return this.dbEvent.id;
  }

  public get start() {
    const dates = ((this.dbEvent.at as string) || "")
      .replaceAll(/["[\]()]/g, "")
      .split(",");
    return toDate(dates[0], this.tz);
  }

  public get end() {
    const dates = ((this.dbEvent.at as string) || "")
      .replaceAll(/["[\]()]/g, "")
      .split(",");
    return toDate(dates[1], this.tz);
  }

  public get name() {
    if (this.dbEvent.name) {
      return this.dbEvent.name;
    }
    let title = "Untitled event";
    if (this.invitees.length > 1) {
      title = "Meeting";
      const names = this.invitees
        .filter((a) => !a.isSelf)
        .map((a) => a.name || a.email);
      switch (names.length) {
        case 0:
          break;
        case 1:
          title += ` with ${names[0]}`;
          break;
        case 2:
          title += ` with ${names[0]} and ${names[1]}`;
          break;
        default:
          title += ` with ${names.slice(0, 2).join(", ")}, and ${
            names.length - 2
          } other${names.length - 2 > 1 ? "s" : ""}`;
          break;
      }
    }
    return title;
  }

  public get description() {
    return this.dbEvent.description;
  }

  // calendar owner's response
  public get response() {
    return this.invitees.find((invitee) => invitee.isSelf)?.response || null;
  }

  // email address associated with the calendar that owns this event
  public get email() {
    return this.invitees.find((invitee) => invitee.isSelf)?.email || null;
  }

  public get providerLink() {
    return this.dbEvent.provider_link;
  }

  public get conferencingUrl() {
    return this.dbEvent.conferencing_url;
  }

  public get invitees() {
    return this.dbEvent.invitees.map((invitee) => ({
      id: invitee.contact?.id,
      name: invitee.contact?.name || invitee.contact?.email,
      email: invitee.contact?.email,
      // This assume contact_user_id is only set for the owner
      isSelf: !!invitee.contact?.contact_user_id,
      response: invitee.response,
    }));
  }
}

// export async function getCredentials(
//   supabase: SupabaseClient,
// ) {
//   return safeQuery(
//     await supabase
//       .from("event")
//       .select(
//         "*,invitees:invitee(response,is_optional,contact(id,name,email,contact_user_id))"
//       )
//       .overlaps("at", during)
//       .neq("status", "cancelled")
//       .order("at", { ascending: forward })
//       .limit(100)
//   );
//   // config: CalendarConfig,
//   // credentials: CalendarCredentials,
//   // calendarId: string,
// }

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
  type retType = NonNullable<typeof events>;
  if (!events) return [] as retType;

  return events.filter((e) => !!e) as retType;
}

export function EventList({ events, tz }: { events: Event[]; tz: string }) {
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

  let last: Date | undefined;
  return (
    <Stack>
      {events.map((event) => {
        const isNewDay = !last || !isSameDay(last, event.start, event.tz);
        last = event.start;
        return (
          <React.Fragment key={event.id}>
            {isNewDay && <Title order={3}>{formatDay(event.start, tz)}</Title>}
            <EventCard event={event} tz={tz} />
          </React.Fragment>
        );
      })}
    </Stack>
  );
}

export default function EventCard({ event, tz }: { event: Event; tz: string }) {
  const [response, setResponseState] = useState(event.response || undefined);
  const updater = useEventUpdater();
  const setResponse = useCallback(
    (checked: boolean) => {
      const response = checked ? "accepted" : "declined";
      setResponseState(response);
      const email = event.email;
      if (!email) throw new Error("Missing calendar email");
      updater(event.id, {
        response: {
          response,
          email,
        },
      });
    },
    [event, updater]
  );
  return (
    <Card withBorder>
      <Stack>
        <Title order={3}>
          {event.name}{" "}
          {event.providerLink && (
            <Anchor target="_blank" href={event.providerLink}>
              <IconExternalLink />
            </Anchor>
          )}
        </Title>
        <Text>{formatTimes(event.start, event.end, tz)}</Text>
        <Box>
          <Chip checked={response === "accepted"} onChange={setResponse}>
            Attend
          </Chip>
        </Box>
        {event.invitees.length > 1 && (
          <Group gap="xs">
            {event.invitees.map((invitee) => (
              <Pill key={invitee.id}>{invitee.name}</Pill>
            ))}
          </Group>
        )}
        {event.description && (
          <Box dangerouslySetInnerHTML={{ __html: event.description }} />
        )}
        {event.conferencingUrl && (
          <Group>
            <Button
              variant="light"
              component="a"
              target="_blank"
              href={event.conferencingUrl}
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
