import { useCallback, useEffect, useState } from "react";

import {
  Box,
  Button,
  Flex,
  Group,
  Input,
  Modal,
  NumberInput,
  Progress,
  Stack,
  Table,
  Text,
  Tooltip,
} from "@mantine/core";
import { useDisclosure } from "@mantine/hooks";

import {
  IconArrowDownLeft,
  IconArrowUpRight,
  IconEdit,
  IconTrash,
} from "@tabler/icons-react";

import { formatDuration } from "@plotday/tz";

import classes from "./tuner.module.css";

type Stats = {
  event_count: number;
  minutes: number;
};

export type LabelStats = {
  id: number;
  tag: string;
  name?: string;
  description?: string;
  accepted?: Stats;
  declined?: Stats;
  tentative?: Stats;
};

export type LabelStatsMap = {
  [id: number]: LabelStats;
};

export function TunerList({
  labelStats,
  previousStats,
  monthlyWorkingMinutes,
  previousMonthlyWorkingMinutes,
  weeklyWorkingMinutes,
  targets,
  onTargetChange,
  org,
}: {
  labelStats: LabelStatsMap;
  previousStats: LabelStatsMap;
  monthlyWorkingMinutes: number;
  previousMonthlyWorkingMinutes: number;
  weeklyWorkingMinutes: number;
  targets: Record<number, number>;
  onTargetChange: (
    labelId: number,
    target: number | null,
    org: boolean
  ) => void;
  org: boolean;
}) {
  const sortedStats = Object.values(labelStats).sort(
    (a, b) => (b.accepted?.minutes || 0) - (a.accepted?.minutes || 0)
  );

  const maxMinutes = sortedStats.reduce(
    (m, stats) =>
      Math.max(
        m,
        (stats.accepted?.minutes || 0) + (stats.tentative?.minutes || 0)
      ),
    Object.values(targets).reduce(
      (m, target) =>
        Math.max(m, (target / weeklyWorkingMinutes) * monthlyWorkingMinutes),
      0
    )
  );

  return (
    <Table.ScrollContainer minWidth={500}>
      <Table>
        <Table.Thead>
          <Table.Tr>
            <Table.Th pl={0}></Table.Th>
            <Table.Th>Balance</Table.Th>
            <Table.Th colSpan={3}>Scheduled</Table.Th>
            <Table.Th />
            <Table.Th colSpan={2} ta="right">
              Pending
            </Table.Th>
            <Table.Th>Budget</Table.Th>
          </Table.Tr>
        </Table.Thead>
        <Table.Tbody>
          {sortedStats.map((stats) => (
            <Tuner
              key={stats.id}
              labelStats={stats}
              previousStats={previousStats[stats.id]}
              monthlyWorkingMinutes={monthlyWorkingMinutes}
              previousMonthlyWorkingMinutes={previousMonthlyWorkingMinutes}
              weeklyWorkingMinutes={weeklyWorkingMinutes}
              maxMinutes={maxMinutes}
              targets={targets}
              onTargetChange={onTargetChange}
              org={org}
            />
          ))}
        </Table.Tbody>
      </Table>
    </Table.ScrollContainer>
  );
}

function TargetModal({
  labelStats,
  onTargetChange,
  org,
  opened,
  close,
  targetMinutes,
  weeklyMinutes,
}: {
  labelStats: LabelStats;
  onTargetChange: (
    labelId: number,
    target: number | null,
    org: boolean
  ) => void;
  org: boolean;
  opened: boolean;
  close: () => void;
  targetMinutes?: number;
  weeklyMinutes: number;
}) {
  const defaultHours = Math.floor(
    (targetMinutes !== undefined ? targetMinutes : weeklyMinutes) / 60
  );
  const defaultMinutes =
    (targetMinutes !== undefined
      ? targetMinutes
      : Math.floor(weeklyMinutes / 15) * 15) % 60;

  const [hours, setHours] = useState<number>(defaultHours);
  const [minutes, setMinutes] = useState<number>(defaultMinutes);

  useEffect(() => {
    setHours(defaultHours);
    setMinutes(defaultMinutes);
  }, [opened, setHours, setMinutes, defaultHours, defaultMinutes]);

  const onHourChange = useCallback((value: number) => {
    setHours(value);
  }, []);
  const onMinuteChange = useCallback((value: number) => {
    if (value === 60) {
      setHours((h) => h + 1);
      setMinutes(0);
    } else if (value < 0) {
      setHours((h) => h - 1);
      setMinutes(60 + value);
    } else {
      setMinutes(value);
    }
  }, []);

  const updateTarget = useCallback(() => {
    const total = hours * 60 + minutes;
    onTargetChange(labelStats.id, total, org);
    close();
  }, [hours, minutes, close, org, labelStats, onTargetChange]);
  const clearTarget = useCallback(() => {
    onTargetChange(labelStats.id, null, org);
    close();
  }, [close, org, labelStats, onTargetChange]);

  return (
    <Modal
      opened={opened}
      onClose={close}
      title={`Budget for ${labelStats.tag} ${labelStats.name ?? ""}`}
    >
      <Stack gap="lg">
        <Input.Wrapper label="Hours per week">
          <Group gap="xs">
            <NumberInput
              data-autofocus
              placeholder="HH"
              ta="right"
              w="4.5rem"
              value={hours}
              onChange={onHourChange}
              allowNegative={false}
              allowDecimal={false}
              className={classes.hourInput}
            />
            <Text>:</Text>
            <NumberInput
              placeholder="MM"
              w="4.5rem"
              prefix={minutes < 10 ? "0" : ""}
              value={minutes}
              onChange={onMinuteChange}
              allowNegative={false}
              allowDecimal={false}
              allowLeadingZeros
              min={-15}
              max={60}
              step={15}
            />
            {targetMinutes !== undefined && (
              <Button
                onClick={clearTarget}
                variant="subtle"
                c="secondary"
                title="Clear budget"
              >
                <IconTrash stroke={1} />
              </Button>
            )}
          </Group>
        </Input.Wrapper>
        <Button onClick={updateTarget}>Set budget</Button>
      </Stack>
    </Modal>
  );
}

export function Tuner({
  labelStats,
  previousStats,
  monthlyWorkingMinutes,
  previousMonthlyWorkingMinutes,
  weeklyWorkingMinutes,
  maxMinutes,
  targets,
  onTargetChange,
  org,
}: {
  labelStats: LabelStats;
  previousStats?: LabelStats;
  monthlyWorkingMinutes: number;
  previousMonthlyWorkingMinutes: number;
  weeklyWorkingMinutes: number;
  maxMinutes: number;
  targets: Record<number, number>;
  onTargetChange: (
    labelId: number,
    target: number | null,
    org: boolean
  ) => void;
  org: boolean;
}) {
  const toWeekly = (min: number) =>
    (min / monthlyWorkingMinutes) * weeklyWorkingMinutes;
  const toMonthly = (min: number) =>
    (min / weeklyWorkingMinutes) * monthlyWorkingMinutes;

  const monthlyMinutes = labelStats.accepted?.minutes || 0;
  const weeklyMinutes = toWeekly(monthlyMinutes);
  const previousMinutes = previousStats?.accepted?.minutes || 0;
  const pendingMinutes = labelStats.tentative?.minutes || 0;
  const count = labelStats.accepted?.event_count || 0;
  const pendingCount = labelStats.tentative?.event_count || 0;

  let weeklyTargetMinutes: number | undefined = undefined;
  let monthlyTargetMinutes: number | undefined = undefined;
  let goodMinutes = monthlyMinutes;
  let badMinutes = 0;
  let goodPending = 0;
  let badPending = pendingMinutes;
  if (targets[labelStats.id] !== undefined) {
    weeklyTargetMinutes = targets[labelStats.id];
    monthlyTargetMinutes = toMonthly(weeklyTargetMinutes);
    goodMinutes = Math.min(monthlyMinutes, monthlyTargetMinutes);
    badMinutes = monthlyMinutes - goodMinutes;
    goodPending = Math.min(pendingMinutes, monthlyTargetMinutes - goodMinutes);
    badPending = pendingMinutes - goodPending;
  }
  const scheduledMinutes = Math.max(monthlyMinutes, monthlyTargetMinutes || 0);

  const load = (monthlyMinutes / monthlyWorkingMinutes) * 100;
  const previousLoad = (previousMinutes / previousMonthlyWorkingMinutes) * 100;
  const trend = previousLoad
    ? Math.round(((load - previousLoad) / previousLoad) * 100)
    : 0;

  const [opened, { open, close }] = useDisclosure(false);

  return (
    <>
      <TargetModal
        weeklyMinutes={weeklyMinutes}
        {...{
          labelStats,
          onTargetChange,
          org,
          opened,
          close,
          targetMinutes: weeklyTargetMinutes,
        }}
      />
      <Table.Tr>
        <Table.Td w="7rem" pl={0}>
          <Tooltip
            label={labelStats.description}
            disabled={!labelStats.description}
          >
            <Text inherit truncate w="7rem">
              {labelStats.tag} {labelStats.name}{" "}
            </Text>
          </Tooltip>
        </Table.Td>
        <Table.Td
          className={classes.number}
          c={
            monthlyTargetMinutes !== undefined &&
            monthlyTargetMinutes <= monthlyMinutes
              ? "secondary"
              : "brand"
          }
          miw="5rem"
        >
          {monthlyTargetMinutes !== undefined
            ? formatDuration(monthlyTargetMinutes - monthlyMinutes)
            : ""}
        </Table.Td>
        <Table.Td
          className={classes.number}
          c={badMinutes ? "secondary" : "dimmed"}
        >
          <Text inherit miw="2.8rem" ta="right">
            {monthlyMinutes ? formatDuration(monthlyMinutes) : ""}
          </Text>
        </Table.Td>
        <Table.Td className={classes.fitContent} pl={0}>
          <Text className={classes.badge}>{count ? count : ""}</Text>
        </Table.Td>
        <Table.Td className={classes.fitContent} pl={0}>
          {trend !== 0 && (
            <Text inherit fz="xs" c={trend > 0 ? "secondary" : "brand"}>
              {trend > 0 ? (
                <IconArrowUpRight size="1em" />
              ) : (
                <IconArrowDownLeft size="1em" />
              )}
              {Math.abs(trend)}%
            </Text>
          )}
        </Table.Td>
        <Table.Td miw="6rem">
          <Group gap={0} wrap="nowrap">
            <Progress.Root
              w={`${(scheduledMinutes / maxMinutes) * 100}%`}
              size="md"
            >
              <Progress.Section value={0} color="brand" />
              {goodMinutes / scheduledMinutes > 0 && (
                <Progress.Section
                  value={(goodMinutes / scheduledMinutes) * 100}
                  color="brand"
                />
              )}
              {badMinutes / scheduledMinutes > 0 && (
                <Progress.Section
                  value={(badMinutes / scheduledMinutes) * 100}
                  color="secondary"
                />
              )}
            </Progress.Root>
            <Box
              ml="xs"
              mr="xs"
              w={`${
                ((maxMinutes - scheduledMinutes - pendingMinutes) /
                  maxMinutes) *
                100
              }%`}
            />
            <Progress.Root
              w={`${(pendingMinutes / maxMinutes) * 100}%`}
              size="md"
              dir="rtl"
            >
              <Progress.Section value={0} color="brand" />
              {goodPending / pendingMinutes > 0 && (
                <Progress.Section
                  value={(goodPending / pendingMinutes) * 100}
                  color="brand"
                />
              )}
              {badPending / pendingMinutes > 0 && (
                <Progress.Section
                  value={(badPending / pendingMinutes) * 100}
                  color="secondary"
                />
              )}
            </Progress.Root>
          </Group>
        </Table.Td>
        <Table.Td
          className={classes.number}
          c={
            weeklyTargetMinutes !== undefined && badPending
              ? "secondary"
              : "dimmed"
          }
        >
          <Text inherit miw="2.8rem" ta="right">
            {pendingMinutes ? formatDuration(pendingMinutes) : ""}
          </Text>
        </Table.Td>
        <Table.Td className={classes.fitContent} pl={0}>
          <Text className={classes.badge}>
            {pendingCount ? pendingCount : ""}
          </Text>
        </Table.Td>
        <Table.Td className={classes.number} pt={0} pb={0} pr={0}>
          {weeklyTargetMinutes === undefined && (
            <Button
              onClick={open}
              variant="subtle"
              size="xs"
              fullWidth
              className={classes.cellButton}
              styles={{
                inner: {
                  justifyContent: "flex-end",
                },
              }}
              title="Set budget"
            >
              <IconEdit size="1rem" />
            </Button>
          )}
          {weeklyTargetMinutes !== undefined &&
            monthlyTargetMinutes !== undefined && (
              <Button
                onClick={open}
                variant="subtle"
                size="xs"
                fz="sm"
                fw="normal"
                fullWidth
                className={classes.cellButton}
                styles={{
                  inner: {
                    justifyContent: "flex-end",
                  },
                }}
                title="Edit budget"
              >
                {formatDuration(monthlyTargetMinutes).padStart(5, " ")}
              </Button>
            )}
        </Table.Td>
      </Table.Tr>
    </>
  );
}
