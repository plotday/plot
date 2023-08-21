import React, { useCallback, useState } from "react";

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

import type { Event } from "@plotday/db";
import { formatDay, formatTimes, isSameDay } from "@plotday/tz";

import { useEventWatch } from "app/event";
import { useEventResponder } from "app/routes/api.response";

export function EventList({ events }: { events: Event[] }) {
  useEventWatch();

  let last: Date | undefined;
  return (
    <Stack>
      {events
        .reduce((acc, event) => {
          if (event.isAllDay) {
            if (acc.length === 0 || !Array.isArray(acc[acc.length - 1])) {
              acc.push([]);
            }
            // @ts-ignore
            acc[acc.length - 1].push(event);
          } else {
            acc.push(event);
          }
          return acc;
        }, [] as (Event | Event[])[])
        .map((event) => {
          // @ts-ignore
          let events: Event[] = [];
          if (Array.isArray(event)) {
            events = event;
          }
          const firstEvent: Event = Array.isArray(event) ? event[0] : event;
          const isNewDay =
            !last || !isSameDay(last, firstEvent.start, firstEvent.tz);
          last = firstEvent.start;
          return (
            <React.Fragment key={firstEvent.id}>
              {isNewDay && (
                <Title order={3}>
                  {formatDay(firstEvent.start, firstEvent.tz)}
                </Title>
              )}
              {events.length > 0 && (
                <Text fs="italic">{events.map((e) => e.name).join(", ")}</Text>
              )}
              {!firstEvent.isAllDay && <EventCard event={firstEvent} />}
            </React.Fragment>
          );
        })}
    </Stack>
  );
}

export default function EventCard({ event }: { event: Event }) {
  const [response, setResponseState] = useState(event.response || undefined);
  const responder = useEventResponder();
  const setResponse = useCallback(
    (checked: boolean) => {
      const response = checked ? "accepted" : "declined";
      setResponseState(response);
      const email = event.email;
      if (!email) throw new Error("Missing calendar email");
      responder(event.id, response, email, event.isOrganizer);
    },
    [event, responder]
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
        <Text>{formatTimes(event.start, event.end, event.tz)}</Text>
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
        {event.labels.length > 0 && (
          <Group gap="xs">
            {event.labels.map((label) => (
              <Pill key={label.id}>{label.name}</Pill>
            ))}
          </Group>
        )}
      </Stack>
    </Card>
  );
}
