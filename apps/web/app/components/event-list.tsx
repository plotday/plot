import React, { memo, useMemo } from "react";

import { Link, useLocation } from "@remix-run/react";

import {
  Anchor,
  Avatar,
  Badge,
  Box,
  Card,
  Center,
  Group,
  Paper,
  Stack,
  Text,
  Title,
  Tooltip,
} from "@mantine/core";
import { useHover } from "@mantine/hooks";

import {
  IconBrandMicrosoftTeams,
  IconBrandZoom,
  IconClipboardList,
  IconVideo,
} from "@tabler/icons-react";

import type {
  Attendance,
  ConferencingProvider,
  Event,
  Invitee,
  Label,
} from "@plotday/db";
import {
  formatDate,
  formatDay,
  formatDifference,
  formatDuration,
  formatTime,
} from "@plotday/tz";

import { useEventWatch } from "app/event";
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

export function EventList({
  events,
  targets,
  expenditures,
  review,
  showGaps,
}: {
  events: Event[];
  targets: {
    targets: Record<number, number>;
    orgTargets: Record<number, number>;
  };
  expenditures: DailyLabelStats;
  review?: boolean;
  showGaps?: boolean;
}) {
  showGaps = showGaps ?? false;
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
                stats.attend?.minutes !== undefined
              ) {
                balances[stats.id] =
                  targets.targets[stats.id] * 4 - (stats.attend?.minutes ?? 0);
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
    <Box>
      {Object.keys(groupedEvents).map((day) => {
        let previousEvent: Event | null = null;
        return (
          <React.Fragment key={day}>
            <Paper
              bg="var(--mantine-color-background)"
              radius={0}
              h="4rem"
              pl="1rem"
              style={{
                position: "sticky",
                top: 0,
                zIndex: 99,
                gridColumn: "1 / span 2",
              }}
            >
              <Title fw="normal" order={3} fz="md" pt="md">
                {day}
              </Title>
            </Paper>

            <AllDayCard events={groupedEvents[day].allDay} />

            <Box pt="0.5rem">
              {groupedEvents[day].regular.map((event) => {
                const before = previousEvent;
                previousEvent = event.event;
                return (
                  <React.Fragment key={event.event.id}>
                    {showGaps && (
                      <BreakCard before={before} after={event.event} />
                    )}
                    <EventCard
                      event={event.event}
                      balances={event.balances}
                      review={review}
                    />
                  </React.Fragment>
                );
              })}
              {showGaps && <BreakCard before={previousEvent} after={null} />}
            </Box>
          </React.Fragment>
        );
      })}
    </Box>
  );
}

function TimeCard({
  start,
  end,
  tz,
  alert,
  dimmed,
  selected,
  children,
}: {
  start: Date;
  end?: Date;
  tz: string;
  alert?: boolean;
  dimmed?: boolean;
  selected?: boolean;
  children?: React.ReactNode;
}) {
  return (
    <Box display="grid" style={{ gridTemplateColumns: "5rem 2px 1fr" }}>
      <Stack gap="xs" pr="xs">
        <Text
          size="sm"
          ta="right"
          mt="calc(var(--mantine-font-size-sm) * var(--mantine-line-height-sm) * -0.5 - 1px)"
        >
          {formatTime(start, tz)}
        </Text>
        {end && (
          <Text size="sm" ta="right" c="dimmed">
            {formatDifference(start, end)}
          </Text>
        )}
      </Stack>
      <Box
        w="2px"
        h={children ? undefined : 0}
        bg={
          alert === undefined
            ? "var(--mantine-color-default-border)"
            : alert
            ? selected
              ? "secondary"
              : "var(--mantine-color-secondary-dimmed)"
            : selected
            ? "brand"
            : "var(--mantine-color-brand-dimmed)"
        }
        style={
          alert === undefined
            ? {}
            : {
                borderTop: "1px solid var(--mantine-color-background)",
                borderBottom: "1px solid var(--mantine-color-background)",
              }
        }
      />
      <Card
        radius={0}
        style={{
          borderTop: "1px solid var(--mantine-color-background)",
          borderBottom: "1px solid var(--mantine-color-background)",
        }}
        bg={dimmed ? "var(--mantine-color-background)" : undefined}
        p={children ? undefined : 0}
        h={children ? undefined : 0}
      >
        {children}
      </Card>
    </Box>
  );
}

function AllDayCard({ events }: { events: Event[] }) {
  if (events.length === 0) return null;
  return (
    <Paper
      bg="var(--mantine-color-background)"
      mb="lg"
      style={{
        gridColumn: "1 / span 2",
        zIndex: 98,
      }}
    >
      <Text fs="italic">{events.map((e) => e.name).join(", ")}</Text>
    </Paper>
  );
}

function BreakCard({
  before,
  after,
}: {
  before: Event | null;
  after: Event | null;
}) {
  if (before && !after) {
    return <TimeCard start={before.end} tz={before.tz} />;
  }
  if (!before || !after || after.start.getTime() <= before.end.getTime()) {
    return null;
  }
  return (
    <TimeCard
      start={before.end}
      end={after.start}
      tz={(before || after).tz}
      alert={false}
      dimmed
    >
      <Box mih="2rem" />
    </TimeCard>
  );
}

function initials(name: string) {
  let names;
  if (name.includes("@")) {
    names = name.toUpperCase().split("@")[0].split(".");
  } else {
    names = name.toUpperCase().split(" ");
  }
  let initials = names[0][0];
  if (names.length > 1) {
    initials += names[names.length - 1][0];
  }
  return initials;
}

function InviteeAvatar({ invitee }: { invitee: Invitee }) {
  const generatedInitials = useMemo(
    () => initials(invitee?.name || invitee?.email || "?"),
    [invitee]
  );
  const color =
    invitee.response === "accepted"
      ? "var(--mantine-color-brand-filled)"
      : invitee.response === "declined"
      ? "var(--mantine-color-secondary-filled)"
      : "var(--mantine-color-neutral)";
  return (
    <Tooltip
      key={invitee.email}
      label={`${invitee.name || invitee.email} ${
        invitee.response === "accepted"
          ? " ✅"
          : invitee.response === "declined"
          ? " ❌"
          : ""
      }`}
      withArrow
    >
      <Avatar
        src={invitee.avatar || undefined}
        imageProps={{ referrerPolicy: "no-referrer" }}
        alt={invitee.name || undefined}
        style={{
          border: `2px solid ${color}`,
        }}
        color={
          invitee.response === "accepted"
            ? "brand"
            : invitee.response === "declined"
            ? "secondary.7"
            : undefined
        }
      >
        {generatedInitials}
      </Avatar>
    </Tooltip>
  );
}

function KeyPerson({
  invitees,
  organizer,
}: {
  invitees: Invitee[];
  organizer?: Invitee;
}) {
  const p = useMemo(() => {
    return invitees.find((i) => i.email === organizer?.email);
  }, [organizer, invitees]);

  if (!p) {
    return null;
  }
  return <InviteeAvatar invitee={p} />;
}

const InviteeSummary = memo(function InviteeSummary({
  invitees,
  organizer,
}: {
  invitees: Invitee[];
  organizer?: Invitee;
}) {
  const others = useMemo(
    () =>
      invitees
        .filter((i) => !i.isSelf && i.email !== organizer?.email)
        .map((i) => ({ ...i, initials: initials(i.name || i.email || "?") })),
    [invitees, organizer]
  );
  if (others.length === 0) return null;
  return (
    <Tooltip.Group>
      <Avatar.Group>
        {others.map((invitee) => (
          <InviteeAvatar invitee={invitee} key={invitee.email} />
        ))}
      </Avatar.Group>
    </Tooltip.Group>
  );
});

const Labels = memo(function Labels({
  labels,
  balances,
  attendance,
}: {
  labels: Label[];
  balances: Record<number, number>;
  attendance: Attendance;
}) {
  if (!labels.length) return null;
  return (
    <Group>
      {labels.map((label) => {
        const balance = balances[label.id];
        return (
          <Tooltip
            key={label.id}
            label={
              balance
                ? `${formatDuration(Math.abs(balance / 4))} per week ${
                    balance < 0 ? "over goal" : "under goal"
                  }`
                : null
            }
            disabled={!balance}
          >
            <Badge
              color={
                attendance !== "skip" && balance < 0 ? "secondary" : "gray"
              }
              fw={500}
              tt="unset"
            >
              {label.tag} {label.name}
            </Badge>
          </Tooltip>
        );
      })}
    </Group>
  );
});

function EventCard({
  event,
  balances,
  review,
  selected,
}: {
  event: Event;
  balances: Record<number, number>;
  review?: boolean;
  selected?: boolean;
}) {
  const { hovered, ref } = useHover();
  selected = hovered;

  const location = useLocation();
  const rootPath = "/" + location.pathname.split("/")[1];

  return (
    <div ref={ref}>
      <Anchor
        component={Link}
        to={`${rootPath}/${event.id}`}
        underline="never"
        c="var(--mantine-color-text)"
      >
        <TimeCard
          start={event.start}
          end={event.end}
          tz={event.tz}
          alert={!event.isDone(!!review)}
          selected={selected}
        >
          <Box
            display="grid"
            style={{
              gridTemplateColumns: "min-content 1fr",
              columnGap: "var(--mantine-spacing-md)",
              rowGap: "var(--mantine-spacing-md)",
            }}
          >
            <Center>
              {event.type === "task" ? (
                <Avatar alt="Task">
                  <IconClipboardList color="var(--mantine-color-dimmed)" />
                </Avatar>
              ) : (
                <KeyPerson
                  invitees={event.invitees}
                  organizer={event.organizer}
                />
              )}
            </Center>
            <Group>
              <Stack gap={0}>
                <Text
                  c={selected ? "var(--mantine-color-text-bold)" : undefined}
                  fw={event.attendance === "skip" ? "normal" : "bold"}
                >
                  {event.name}
                </Text>
                {event.conferencing && (
                  <Group gap="xs" align="center">
                    <ConferencingIcon provider={event.conferencing.provider} />
                    <Text fz="xs" c="dimmed" lh={0}>
                      {conferencingProviderName(event.conferencing.provider)}
                    </Text>
                  </Group>
                )}
              </Stack>
              <InviteeSummary
                invitees={event.invitees}
                organizer={event.organizer}
              />
            </Group>

            {event.labels.length > 0 && (
              <>
                <Box />
                <Labels
                  labels={event.labels}
                  balances={balances}
                  attendance={event.attendance}
                />
              </>
            )}
          </Box>
        </TimeCard>
      </Anchor>
    </div>
  );
}
