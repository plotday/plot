import type { ReactNode } from "react";
import React, { useCallback, useEffect, useMemo, useState } from "react";

import {
  Anchor,
  Avatar,
  Badge,
  Box,
  Card,
  Center,
  Checkbox,
  Combobox,
  Group,
  InputBase,
  Paper,
  Stack,
  Text,
  Title,
  Tooltip,
  useCombobox,
} from "@mantine/core";

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
import { useEventReadyResponder } from "app/routes/api.event.ready";
import { useEventResponder } from "app/routes/api.response";
import type { DailyLabelStats } from "app/target";

import classes from "./event.module.css";

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
  const name = conferencingProviderName(provider);
  let icon;
  switch (provider) {
    case "zoom":
      icon = <IconBrandZoom size="1em" />;
    case "teams":
      icon = <IconBrandMicrosoftTeams size="1em" />;
    case "meet":
    default:
      icon = <IconVideo size="1em" />;
  }
  return <Tooltip label={name}>{icon}</Tooltip>;
}

export function EventList({
  events,
  targets,
  expenditures,
  review,
  showDone,
}: {
  events: Event[];
  targets: {
    targets: Record<number, number>;
    orgTargets: Record<number, number>;
  };
  expenditures: DailyLabelStats;
  review?: boolean;
  showDone?: boolean;
}) {
  showDone = showDone ?? true;
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
        } else if (!showDone && event.isDone(review)) {
          // skip
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
  }, [events, expenditures, targets, review, showDone]);

  return (
    <Box mt="-1rem">
      {Object.keys(groupedEvents).map((day) => {
        let previousEvent: Event | null = null;
        return (
          <React.Fragment key={day}>
            <Paper
              bg="var(--mantine-color-background)"
              radius={0}
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

            <AllDayCard events={groupedEvents[day].allDay} />

            <Box pt="0.5rem">
              {groupedEvents[day].regular.map((event) => {
                const before = previousEvent;
                previousEvent = event.event;
                return (
                  <React.Fragment key={event.event.id}>
                    {showDone && (
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
              {showDone && <BreakCard before={previousEvent} after={null} />}
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
  children,
}: {
  start: Date;
  end?: Date;
  tz: string;
  children?: React.ReactNode;
}) {
  return (
    <Box display="grid" style={{ gridTemplateColumns: "5rem 1fr" }}>
      <Stack
        gap="xs"
        mt="calc(var(--mantine-font-size-sm) * var(--mantine-line-height-sm) * -0.5)"
        mr="sm"
      >
        <Text size="sm" ta="right">
          {formatTime(start, tz)}
        </Text>
        {end && (
          <Text size="sm" ta="right" c="dimmed">
            {formatDifference(start, end)}
          </Text>
        )}
      </Stack>
      {children && (
        <Card radius={0} className={classes.timeCardMain}>
          {children}
        </Card>
      )}
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
  if (!before || !after || after.start.getTime() <= before.end.getTime())
    return null;
  return (
    <TimeCard start={before.end} end={after.start} tz={(before || after).tz}>
      <Box>
        <Text c="dimmed" fs="italic">
          Open time
        </Text>
      </Box>
    </TimeCard>
  );
}

function Select({
  value,
  onChange,
  options,
}: {
  value?: string;
  onChange: (value: string) => void;
  options: { value: string; label: ReactNode }[];
}) {
  const combobox = useCombobox({
    onDropdownClose: () => combobox.resetSelectedOption(),
  });

  const selectedOption = options.find((item) => item.value === value);

  return (
    <Combobox
      store={combobox}
      onOptionSubmit={(val) => {
        onChange(val);
        combobox.closeDropdown();
      }}
      variant="filled"
    >
      <Combobox.Target>
        <InputBase
          component="button"
          pointer
          rightSection={<Combobox.Chevron />}
          onClick={() => combobox.toggleDropdown()}
          rightSectionPointerEvents="none"
          multiline
          variant="filled"
          w="8rem"
        >
          {selectedOption ? (
            selectedOption.label
          ) : (
            <Text inherit c="secondary" fw="bold">
              Triage
            </Text>
          )}
        </InputBase>
      </Combobox.Target>

      <Combobox.Dropdown>
        <Combobox.Options>
          {options.map((item) => (
            <Combobox.Option value={item.value} key={item.value}>
              {item.label}
            </Combobox.Option>
          ))}
        </Combobox.Options>
      </Combobox.Dropdown>
    </Combobox>
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

function KeyPerson({
  invitees,
  organizer,
}: {
  invitees: Invitee[];
  organizer?: Invitee;
}) {
  const others = invitees.filter((i) => !i.isSelf);
  if (!others.length) {
    return (
      <Avatar alt="Task">
        <IconClipboardList color="var(--mantine-color-dimmed)" />
      </Avatar>
    );
  }
  let p = null;
  if (others.length === 1) {
    p = others[0];
  } else {
    p = invitees.find((i) => i.email === organizer?.email) || {
      ...organizer,
      response: "accepted",
    };
  }
  return (
    <Tooltip key={p.email} label={p.name || p.email || undefined} withArrow>
      <Avatar
        alt={p.name || undefined}
        color={
          p.response === "accepted"
            ? "brand"
            : p.response === "declined"
            ? "secondary.7"
            : undefined
        }
      >
        {initials(p.name || p.email || "?")}
      </Avatar>
    </Tooltip>
  );
}

function InviteeSummary({
  invitees,
  organizer,
}: {
  invitees: Invitee[];
  organizer?: Invitee;
}) {
  const others = invitees.filter(
    (i) => !i.isSelf && i.email !== organizer?.email
  );
  if (others.length <= 1) return null;
  return (
    <Tooltip.Group>
      <Avatar.Group>
        {others.map((invitee) => (
          <Tooltip
            key={invitee.id}
            label={invitee.name || invitee.email || undefined}
            withArrow
          >
            <Avatar
              alt={invitee.name || undefined}
              color={
                invitee.response === "accepted"
                  ? "brand"
                  : invitee.response === "declined"
                  ? "secondary.7"
                  : undefined
              }
            >
              {initials(invitee.name || invitee.email || "?")}
            </Avatar>
          </Tooltip>
        ))}
      </Avatar.Group>
    </Tooltip.Group>
  );
}

function EventCard({
  event,
  balances,
  review,
}: {
  event: Event;
  balances: Record<number, number>;
  review?: boolean;
}) {
  const [attendance, setAttendanceState] = useState(event.attendance);
  const responder = useEventResponder();
  const setAttendance = useCallback(
    (attendance: string) => {
      setAttendanceState(attendance as Attendance);
      const email = event.email;
      if (!email) throw new Error("Missing calendar email");
      responder(event.id, attendance as Attendance, email, event.isOrganizer);
    },
    [event, responder]
  );
  useEffect(() => {
    setAttendanceState(event.attendance);
  }, [event.attendance]);
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
    <TimeCard start={event.start} end={event.end} tz={event.tz}>
      <Box
        display="grid"
        style={{
          gridTemplateColumns: "min-content 1fr",
          columnGap: "var(--mantine-spacing-md)",
          rowGap: "var(--mantine-spacing-md)",
        }}
      >
        <Center>
          <KeyPerson invitees={event.invitees} organizer={event.organizer} />
        </Center>
        <Group>
          <Stack gap={0}>
            <Text fw={attendance === "attend" ? "bold" : "normal"}>
              {event.name}
            </Text>
            {event.conferencing && (
              <Anchor href={event.conferencing.url} target="_blank">
                <Group gap="xs" align="center">
                  <ConferencingIcon provider={event.conferencing.provider} />
                  <Text fz="xs" c="dimmed" lh={0}>
                    {conferencingProviderName(event.conferencing.provider)}
                  </Text>
                </Group>
              </Anchor>
            )}
          </Stack>
          <InviteeSummary
            invitees={event.invitees}
            organizer={event.organizer}
          />
        </Group>

        <Center>
          <Checkbox
            radius="xl"
            lh="lg"
            checked={ready}
            disabled={attendance === null}
            color={
              attendance === null
                ? undefined
                : attendance === "attend"
                ? "brand"
                : "var(--mantine-color-neutral)"
            }
            styles={{
              input: {
                ...(attendance !== null && !ready
                  ? { borderColor: "var(--mantine-color-secondary-filled)" }
                  : {}),
              },
            }}
            onChange={(event) => updateReady(event.currentTarget.checked)}
          />
        </Center>
        <Group>
          <Select
            options={[
              { value: "attend", label: review ? "Attended" : "Attend" },
              ...(review
                ? []
                : [{ value: "if-possible", label: "If possible" }]),
              { value: "skip", label: review ? "Skipped" : "Skip" },
            ]}
            value={attendance || undefined}
            onChange={setAttendance}
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
  );
}

function Labels({
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
          <Badge
            key={label.id}
            color={attendance !== "skip" && balance < 0 ? "secondary" : "gray"}
            fw={500}
            tt="unset"
          >
            {label.tag} {label.name}
            {balance ? ` (${formatDuration(balance)})` : null}
          </Badge>
        );
      })}
    </Group>
  );
}
