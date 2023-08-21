import { Badge, Progress, Table, Text, Tooltip } from "@mantine/core";

import { IconArrowDownLeft, IconArrowUpRight } from "@tabler/icons-react";

import { formatDuration } from "@plotday/tz";

import classes from "./tuner.module.css";

// TODO: Make this configurable per user
const CONTEXT_SWITCH_MINUTES = 15;

type Stats = {
  event_count: number;
  minutes: number;
};

export type LabelStats = {
  id: number;
  name: string;
  description?: string;
  accepted?: Stats;
  declined?: Stats;
  tentative?: Stats;
  // scheduled?: Stats;
  // skipped?: Stats;
  // pending?: Stats;
};

export type LabelStatsMap = {
  [id: number]: LabelStats;
};

export function TunerList({
  labelStats,
  previousStats,
  workingMinutes,
  previousWorkingMinutes,
}: {
  labelStats: LabelStatsMap;
  previousStats: LabelStatsMap;
  workingMinutes: number;
  previousWorkingMinutes: number;
}) {
  const sortedStats = Object.values(labelStats).sort(
    (a, b) => (b.accepted?.minutes || 0) - (a.accepted?.minutes || 0)
  );

  const maxMinutes = sortedStats
    .map(
      (stats) =>
        (stats.accepted?.minutes || 0) + (stats.tentative?.minutes || 0)
    )
    .reduce((a, b) => Math.max(a, b), 0);

  return (
    <Table.ScrollContainer minWidth={500}>
      <Table>
        <Table.Thead>
          <Table.Tr>
            <Table.Th>Type</Table.Th>
            <Table.Th colSpan={3}>
              <Tooltip
                label={`Percentage of working hours, with {CONTEXT_SWITCH_MINUTES} minutes of context switching per meeting`}
              >
                <Text>Load</Text>
              </Tooltip>
            </Table.Th>
            <Table.Th colSpan={2} className={classes.fitContent}>
              Scheduled
            </Table.Th>
            <Table.Th colSpan={2} className={classes.fitContent}>
              Pending
            </Table.Th>
          </Table.Tr>
        </Table.Thead>
        <Table.Tbody>
          {sortedStats.map((stats) => (
            <Tuner
              key={stats.id}
              labelStats={stats}
              previousStats={previousStats[stats.id]}
              workingMinutes={workingMinutes}
              previousWorkingMinutes={previousWorkingMinutes}
              maxMinutes={maxMinutes}
            />
          ))}
        </Table.Tbody>
      </Table>
    </Table.ScrollContainer>
  );
}

function round(n: number, digits: number = 0) {
  const mult = Math.pow(10, digits);
  return (Math.round(n * mult) / mult).toFixed(digits);
}

export function Tuner({
  labelStats,
  previousStats,
  workingMinutes,
  previousWorkingMinutes,
  maxMinutes,
}: {
  labelStats: LabelStats;
  previousStats?: LabelStats;
  workingMinutes: number;
  previousWorkingMinutes: number;
  maxMinutes: number;
}) {
  const minutes = labelStats.accepted?.minutes || 0;
  const previousMinutes = previousStats?.accepted?.minutes || 0;
  const pendingMinutes = labelStats.tentative?.minutes || 0;
  const totalMinutes = minutes + pendingMinutes;
  const count = labelStats.accepted?.event_count || 0;
  const pendingCount = labelStats.tentative?.event_count || 0;
  const load =
    ((minutes + count * CONTEXT_SWITCH_MINUTES) / workingMinutes) * 100;
  const previousLoad = (previousMinutes / previousWorkingMinutes) * 100;
  const trend = previousLoad
    ? Math.round(((load - previousLoad) / previousLoad) * 100)
    : 0;
  return (
    <Table.Tr>
      <Table.Td className={classes.fitContent}>
        <Tooltip label={labelStats.description}>
          <Text>{labelStats.name}</Text>
        </Tooltip>
      </Table.Td>
      <Table.Td className={classes.number}>{round(load, 1)}%</Table.Td>
      <Table.Td className={classes.number}>
        {trend !== 0 && (
          <Text fz="sm" c={trend > 0 ? "red" : "green"}>
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
        <Progress
          value={(minutes / totalMinutes) * 100}
          w={`${(totalMinutes / maxMinutes) * 100}%`}
        />
      </Table.Td>
      <Table.Td className={classes.number}>{formatDuration(minutes)}</Table.Td>
      <Table.Td className={classes.number}>
        <Badge color="dark">{count}</Badge>
      </Table.Td>
      <Table.Td className={classes.number}>
        {formatDuration(pendingMinutes)}
      </Table.Td>
      <Table.Td className={classes.number}>
        <Badge color="dark">{pendingCount}</Badge>
      </Table.Td>
    </Table.Tr>
  );
}
