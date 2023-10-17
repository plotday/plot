import { useCallback, useEffect, useState } from "react";

import {
  Button,
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
} from "@tabler/icons-react";

import { formatDuration } from "@plotday/tz";

import classes from "./tuner.module.css";

type Stats = {
  event_count: number;
  minutes: number;
  org_event_count: number;
  org_minutes: number | null;
};

export type LabelStats = {
  id: number;
  tag: string;
  name?: string;
  description?: string;
  attend?: Stats;
  skip?: Stats;
  pending?: Stats;
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
  const sortedStats = Object.values(labelStats);
  const minutesKey = org ? "org_minutes" : "minutes";

  const maxMinutes = sortedStats.reduce(
    (m, stats) =>
      Math.max(
        m,
        (stats.attend?.[minutesKey] || 0) + (stats.pending?.[minutesKey] || 0)
      ),
    Object.values(targets).reduce(
      (m, target) =>
        Math.max(m, (target / weeklyWorkingMinutes) * monthlyWorkingMinutes),
      0
    )
  );

  const hasTargets = Object.values(targets).some(
    (target) => target !== undefined
  );

  if (Object.keys(labelStats).length === 0) {
    return <Text>No data</Text>;
  }

  return (
    <Table.ScrollContainer minWidth={500}>
      <Table>
        <Table.Thead>
          <Table.Tr>
            <Table.Th pl={0}>Type</Table.Th>
            <Table.Th>
              <Progress.Root w="100%" size="xl">
                <Progress.Section value={14} color="brand">
                  <Progress.Label c="var(--mantine-color-default)">
                    scheduled
                  </Progress.Label>
                </Progress.Section>
                <Progress.Section
                  value={14}
                  className={classes.pending}
                  lh="unset"
                >
                  <Progress.Label c="var(--mantine-color-text)" lh="unset">
                    pending
                  </Progress.Label>
                </Progress.Section>
                <Progress.Section value={24} color="secondary">
                  <Progress.Label c="var(--mantine-color-default)" lh="unset">
                    scheduled over goal
                  </Progress.Label>
                </Progress.Section>
                <Progress.Section
                  value={24}
                  className={classes.pendingOverBudget}
                >
                  <Progress.Label c="var(--mantine-color-text)" lh="unset">
                    pending over goal
                  </Progress.Label>
                </Progress.Section>
                <Progress.Section value={24} className={classes.budget}>
                  <Progress.Label c="var(--mantine-color-text)" lh="unset">
                    goal
                  </Progress.Label>
                </Progress.Section>
              </Progress.Root>
            </Table.Th>
            <Table.Th ta="right">hrs/wk</Table.Th>
            <Table.Th></Table.Th>
            <Table.Th ta="center">#</Table.Th>
            <Table.Th ta="right">Goal</Table.Th>
          </Table.Tr>
        </Table.Thead>
        <Table.Tbody>
          {sortedStats
            .filter(
              (stats) =>
                stats.attend?.[minutesKey] || stats.pending?.[minutesKey]
            )
            .map((stats) => (
              <Tuner
                key={stats.id}
                labelStats={stats}
                previousStats={previousStats[stats.id]}
                monthlyWorkingMinutes={monthlyWorkingMinutes}
                previousMonthlyWorkingMinutes={previousMonthlyWorkingMinutes}
                weeklyWorkingMinutes={weeklyWorkingMinutes}
                maxMinutes={maxMinutes}
                target={targets[stats.id]}
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
  labelName,
  onTargetChange,
  opened,
  close,
  targetMinutes,
  defaultTarget,
}: {
  labelName: string;
  onTargetChange: (target: number | null) => void;
  opened: boolean;
  close: () => void;
  targetMinutes?: number;
  defaultTarget: number;
}) {
  const defaultHours = Math.floor(
    (targetMinutes !== undefined ? targetMinutes : defaultTarget) / 60
  );
  const defaultMinutes =
    (targetMinutes !== undefined
      ? targetMinutes
      : Math.floor(defaultTarget / 15) * 15) % 60;

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
      setHours((h) => {
        if (h > 0) {
          setMinutes(60 + value);
          return h - 1;
        }
        return h;
      });
    } else {
      setMinutes(value);
    }
  }, []);

  const updateTarget = useCallback(() => {
    const total = hours * 60 + minutes;
    onTargetChange(total);
    close();
  }, [hours, minutes, close, onTargetChange]);
  const clearTarget = useCallback(() => {
    onTargetChange(null);
    close();
  }, [close, onTargetChange]);

  return (
    <Modal
      opened={opened}
      onClose={close}
      title={`Goal for ${labelName}`}
      size="sm"
    >
      <Stack gap="lg">
        <Group gap="lg">
          <Input.Wrapper>
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
              <Text>hours </Text>
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
              <Text>minutes</Text>
            </Group>
          </Input.Wrapper>
        </Group>
        <Stack gap="xs">
          <Button onClick={updateTarget}>Set goal</Button>
          {targetMinutes !== undefined && (
            <Button onClick={clearTarget} variant="subtle" c="secondary">
              Remove goal
            </Button>
          )}
        </Stack>
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
  target,
  onTargetChange,
  org,
}: {
  labelStats: LabelStats;
  previousStats?: LabelStats;
  monthlyWorkingMinutes: number;
  previousMonthlyWorkingMinutes: number;
  weeklyWorkingMinutes: number;
  maxMinutes: number;
  target?: number;
  onTargetChange: (
    labelId: number,
    target: number | null,
    org: boolean
  ) => void;
  org: boolean;
}) {
  const minutesKey = org ? "org_minutes" : "minutes";
  const countKey = org ? "org_event_count" : "event_count";

  const toWeekly = (min: number) =>
    (min / monthlyWorkingMinutes) * weeklyWorkingMinutes;
  const toMonthly = (min: number) =>
    (min / weeklyWorkingMinutes) * monthlyWorkingMinutes;

  const monthlyMinutes = labelStats.attend?.[minutesKey] || 0;
  const weeklyMinutes = toWeekly(monthlyMinutes);
  const previousMinutes = previousStats?.attend?.[minutesKey] || 0;
  const pendingMinutes = labelStats.pending?.[minutesKey] || 0;
  const count = labelStats.attend?.[countKey] || 0;

  let weeklyTargetMinutes: number | undefined = undefined;
  let monthlyTargetMinutes: number | undefined = undefined;
  let goodMinutes = monthlyMinutes;
  let badMinutes = 0;
  let goodPending = pendingMinutes;
  let badPending = 0;
  if (target !== undefined) {
    weeklyTargetMinutes = target;
    monthlyTargetMinutes = toMonthly(weeklyTargetMinutes);
    goodMinutes = Math.min(monthlyMinutes, monthlyTargetMinutes);
    badMinutes = monthlyMinutes - goodMinutes;
    goodPending = Math.min(pendingMinutes, monthlyTargetMinutes - goodMinutes);
    badPending = pendingMinutes - goodPending;
  }
  const totalMinutes = Math.max(
    monthlyMinutes + pendingMinutes,
    monthlyTargetMinutes || 0
  );

  const load = (monthlyMinutes / monthlyWorkingMinutes) * 100;
  const previousLoad = (previousMinutes / previousMonthlyWorkingMinutes) * 100;
  const trend = previousLoad
    ? Math.round(((load - previousLoad) / previousLoad) * 100)
    : 0;

  const [opened, { open, close }] = useDisclosure(false);

  return (
    <>
      <TargetModal
        labelName={labelStats.name || "Untitled"}
        onTargetChange={(target: number | null) =>
          onTargetChange(labelStats.id, target, org)
        }
        defaultTarget={weeklyMinutes}
        {...{
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
        <Table.Td miw="6rem">
          <Group gap={0} wrap="nowrap">
            <Progress.Root
              w={`${(totalMinutes / maxMinutes) * 100}%`}
              size="md"
            >
              <Progress.Section value={0} color="brand" />
              {goodMinutes > 0 && (
                <Progress.Section
                  value={(goodMinutes / totalMinutes) * 100}
                  color="brand"
                />
              )}
              {badMinutes > 0 && (
                <Progress.Section
                  value={(badMinutes / totalMinutes) * 100}
                  color="secondary"
                />
              )}
              <Progress.Section value={0} color="brand" />
              {goodPending > 0 && (
                <Progress.Section
                  value={(goodPending / totalMinutes) * 100}
                  className={classes.pending}
                />
              )}
              {badPending > 0 && (
                <Progress.Section
                  value={(badPending / totalMinutes) * 100}
                  className={classes.pendingOverBudget}
                />
              )}
            </Progress.Root>
          </Group>
        </Table.Td>
        <Table.Td
          className={classes.number}
          c={badMinutes ? "secondary" : "dimmed"}
          miw="5rem"
        >
          <Text inherit miw="2.8rem" ta="right">
            {weeklyMinutes ? formatDuration(weeklyMinutes, true) : ""}
          </Text>
        </Table.Td>
        <Table.Td className={classes.number} pl={0}>
          {trend !== 0 && (
            <Group
              wrap="nowrap"
              gap={0}
              c={trend > 0 ? "secondary" : "brand"}
              justify="end"
            >
              {trend > 0 ? (
                <IconArrowUpRight size="1em" />
              ) : (
                <IconArrowDownLeft size="1em" />
              )}
              <Text inherit>{Math.abs(trend)}%</Text>
            </Group>
          )}
        </Table.Td>
        <Table.Td className={classes.fitContent} pl={0}>
          <Text className={classes.badge}>{count ? count : ""}</Text>
        </Table.Td>
        <Table.Td className={classes.number} pt={0} pb={0} pr={0} w="5rem">
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
              title="Set goal"
            >
              <IconEdit size="1rem" />
            </Button>
          )}
          {weeklyTargetMinutes !== undefined && (
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
              title="Edit goal"
            >
              {formatDuration(weeklyTargetMinutes, true)}
            </Button>
          )}
        </Table.Td>
      </Table.Tr>
    </>
  );
}
