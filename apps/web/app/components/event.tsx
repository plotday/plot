import React, { useCallback, useEffect, useMemo, useState } from "react";

import {
  Anchor,
  Badge,
  Box,
  Card,
  Center,
  Checkbox,
  Group,
  Paper,
  SegmentedControl,
  Stack,
  Text,
  Title,
} from "@mantine/core";

import {
  IconBrandMicrosoftTeams,
  IconBrandZoom,
  IconExternalLink,
  IconPlayerPauseFilled,
  IconPlayerPlayFilled,
  IconPlayerStopFilled,
  IconUser,
  IconUserCheck,
  IconUserX,
  IconVideo,
} from "@tabler/icons-react";

import type { EventResponse } from "@plotday/cal";
import type { ConferencingProvider, Event } from "@plotday/db";
import { formatDate, formatDay, formatDuration, formatTime } from "@plotday/tz";

import { useEventWatch } from "app/event";
import { useEventReadyResponder } from "app/routes/api.event.ready";
import { useEventResponder } from "app/routes/api.response";
import type { DailyLabelStats } from "app/target";

function conferencingProviderName(provider: ConferencingProvider) {
  switch (provider) {
    case "zoom":
      return "Zoom";
    case "meet":
      return "Google Meet";
    case "teams":
      return "Microsoft Teams";
    default:
      return "Video call";
  }
}

function ConferencingIcon({ provider }: { provider: ConferencingProvider }) {
  switch (provider) {
    case "zoom":
      return <IconBrandZoom size="1em" />;
    case "teams":
      return <IconBrandMicrosoftTeams size="1em" />;
    case "meet":
    default:
      return <IconVideo size="1em" />;
  }
}

function AttendeeIcon({ response }: { response: EventResponse | null }) {
  switch (response) {
    case "accepted":
      return (
        <Text c="brand" lh={0}>
          <IconUserCheck size="1em" />
        </Text>
      );
    case "declined":
      return (
        <Text c="secondary" lh={0}>
          <IconUserX size="1em" />
        </Text>
      );
    default:
      return (
        <Text lh={0}>
          <IconUser size="1em" />
        </Text>
      );
  }
}

export function EventList({
  events,
  targets,
  expenditures,
  review,
}: {
  events: Event[];
  targets: {
    targets: Record<number, number>;
    orgTargets: Record<number, number>;
  };
  expenditures: DailyLabelStats;
  review?: boolean;
}) {
  useEventWatch();

  const groupedEvents = useMemo(() => {
    const balances = {} as Record<number, number>;
    const expenditureIterator = Object.keys(expenditures)[Symbol.iterator]();
    let nextExpenditureDate = expenditureIterator
      ? expenditureIterator.next().value
      : null;
    return events.reduce(
      (acc, event) => {
        const date = formatDay(event.start, event.tz);
        acc[date] ??= {
          allDay: [],
          regular: [],
        };
        if (event.isAllDay) {
          acc[date].allDay.push(event);
        } else {
          while (
            nextExpenditureDate &&
            nextExpenditureDate <=
              formatDate(event.start, event.tz, "yyyy-MM-dd")
          ) {
            for (const stats of Object.values(
              expenditures[nextExpenditureDate]
            )) {
              if (
                targets.targets[stats.id] !== undefined &&
                stats.accepted?.minutes !== undefined
              ) {
                balances[stats.id] =
                  targets.targets[stats.id] * 4 -
                  (stats.accepted?.minutes ?? 0);
              }
            }
            nextExpenditureDate = expenditureIterator
              ? expenditureIterator.next().value
              : null;
          }
          const labelBalances = event.labels.reduce((acc, label) => {
            acc[label.id] = balances[label.id] ?? 0;
            return acc;
          }, {} as Record<number, number>);
          acc[date].regular.push({ event, balances: labelBalances });
        }
        return acc;
      },
      {} as Record<
        string,
        {
          allDay: Event[];
          regular: {
            event: Event;
            balances: Record<number, number>;
          }[];
        }
      >
    );
  }, [events, expenditures, targets]);

  return (
    <Box
      display="grid"
      mt="-1rem"
      style={{ gridTemplateColumns: "5.5rem 1fr" }}
    >
      {Object.keys(groupedEvents).map((day) => {
        return (
          <React.Fragment key={day}>
            <Paper
              bg="var(--mantine-color-background)"
              h="4rem"
              style={{
                position: "sticky",
                top: 0,
                zIndex: 99,
                gridColumn: "1 / span 2",
              }}
            >
              <Title fw="normal" order={3} pt="md">
                {day}
              </Title>
            </Paper>

            {groupedEvents[day].allDay.length > 0 && (
              <Paper
                bg="var(--mantine-color-background)"
                mb="lg"
                style={{
                  gridColumn: "1 / span 2",
                  zIndex: 98,
                }}
              >
                <Text fs="italic">
                  {groupedEvents[day].allDay.map((e) => e.name).join(", ")}
                </Text>
              </Paper>
            )}

            {groupedEvents[day].regular.map((event) => (
              <EventCard
                key={event.event.id}
                event={event.event}
                balances={event.balances}
                review={review}
              />
            ))}
          </React.Fragment>
        );
      })}
    </Box>
  );
}

export default function EventCard({
  event,
  balances,
  review,
}: {
  event: Event;
  balances: Record<number, number>;
  review?: boolean;
}) {
  const [response, setResponseState] = useState(event.response || undefined);
  const responder = useEventResponder();
  const setResponse = useCallback(
    (response: EventResponse) => {
      setResponseState(response);
      const email = event.email;
      if (!email) throw new Error("Missing calendar email");
      responder(event.id, response, email, event.isOrganizer);
    },
    [event, responder]
  );
  useEffect(() => {
    setResponseState(event.response || undefined);
  }, [event.response]);
  const [ready, setReady] = useState(review ? event.isReviewed : event.isReady);
  const eventReadyResponder = useEventReadyResponder();
  const updateReady = (ready: boolean) => {
    setReady(ready);
    if (event.providerId) {
      eventReadyResponder(
        event.providerId,
        review ? undefined : ready,
        review ? ready : undefined
      );
    }
  };

  return (
    <>
      <Paper
        bg="var(--mantine-color-background)"
        style={{
          position: "sticky",
          top: "4rem",
          alignSelf: "start",
          flexGrow: 0,
        }}
      >
        <Stack>
          <Card style={{ borderTopRightRadius: 0, borderBottomRightRadius: 0 }}>
            <Center>
              <Checkbox
                radius="xl"
                size="md"
                checked={ready}
                color={
                  response === "accepted"
                    ? "brand"
                    : "var(--mantine-color-neutral)"
                }
                styles={{
                  input: {
                    borderColor: ready
                      ? undefined
                      : "var(--mantine-color-secondary-filled)",
                  },
                }}
                onChange={(event) => updateReady(event.currentTarget.checked)}
              />
            </Center>
          </Card>
          <Text size="sm" ta="right" mr="sm">
            {formatTime(event.start, event.tz)}
            <br />
            &ndash; {formatTime(event.end, event.tz)}
          </Text>
        </Stack>
      </Paper>
      <Card
        display="grid"
        style={{
          flexGrow: 1,
          gridTemplateColumns: "repeat(auto-fit, minmax(12rem, 1fr))",
          rowGap: "1rem",
          borderTopLeftRadius: 0,
          borderColor: ready
            ? response === "accepted"
              ? "var(--mantine-color-brand-border)"
              : undefined
            : "var(--mantine-color-secondary-border)",
        }}
      >
        <Stack>
          <Title order={4} fw={response === "accepted" ? "bold" : "normal"}>
            {event.name}
          </Title>
          <Box>
            <SegmentedControl
              size="xs"
              data={[
                {
                  label: (
                    <Center>
                      <IconPlayerPlayFilled size="1em" />
                      <Box ml={3}>{review ? "Attended" : "Attend"}</Box>
                    </Center>
                  ),
                  value: "accepted",
                },
                ...(review
                  ? []
                  : [
                      {
                        label: (
                          <Center>
                            <IconPlayerPauseFilled size="1em" />
                            <Box ml={3}>Only if needed</Box>
                          </Center>
                        ),
                        value: "tentative",
                      },
                    ]),
                {
                  label: (
                    <Center>
                      <IconPlayerStopFilled size="1em" />
                      <Box ml={3}>{review ? "Skipped" : "Skip"}</Box>
                    </Center>
                  ),
                  value: "declined",
                },
              ]}
              value={response}
              onChange={setResponse}
            />
          </Box>
          {event.labels.length > 0 && (
            <Group gap="xs">
              {event.labels.map((label) => {
                const balance = balances[label.id];
                return (
                  <Badge
                    key={label.id}
                    color={
                      balance ? (balance < 0 ? "secondary" : "brand") : "gray"
                    }
                    fw={500}
                    tt="unset"
                  >
                    {label.tag} {label.name}
                    {balance ? ` (${formatDuration(balance)})` : null}
                  </Badge>
                );
              })}
            </Group>
          )}
        </Stack>
        <Stack gap="xs">
          {event.conferencingUrl && (
            <Group gap="xs">
              <ConferencingIcon
                provider={event.conferencingProvider || "other"}
              />
              <Anchor
                variant="light"
                component="a"
                target="_blank"
                href={event.conferencingUrl}
              >
                {conferencingProviderName(
                  event.conferencingProvider || "other"
                )}
              </Anchor>
            </Group>
          )}

          {event.providerLink && (
            <Group gap="xs">
              <IconExternalLink size="1em" />
              <Anchor target="_blank" href={event.providerLink}>
                View on calendar
              </Anchor>
            </Group>
          )}
        </Stack>
        <Stack gap="xs">
          {event.invitees.map(
            (invitee) =>
              !invitee.isSelf && (
                <Group key={invitee.id} wrap="nowrap" gap="xs">
                  <AttendeeIcon response={invitee.response} />
                  <Text truncate>{invitee.name}</Text>
                </Group>
              )
          )}
        </Stack>
      </Card>
      <Paper pt="lg" style={{ zIndex: 98 }} />
      <Paper />
    </>
  );
}
