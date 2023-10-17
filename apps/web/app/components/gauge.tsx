import {
  Group,
  RingProgress,
  Stack,
  Text,
  Title,
  Tooltip,
} from "@mantine/core";

import { IconArrowDownLeft, IconArrowUpRight } from "@tabler/icons-react";

import { formatDuration } from "@plotday/tz";

export function Gauge({
  label,
  description,
  actual,
  previousActual,
  weeklyWorkingMinutes,
}: {
  label: string;
  description?: string;
  weeklyWorkingMinutes?: number;
  actual: number | null;
  previousActual: number | null;
  target?: number;
  onTargetChange?: (target: number | null) => void;
}) {
  actual = actual !== null ? Math.round(actual) : null;
  previousActual = previousActual !== null ? Math.round(previousActual) : null;

  const trend =
    actual && previousActual
      ? Math.round(((actual - previousActual) / previousActual) * 100)
      : 0;

  return (
    <Group>
      <Stack>
        <Title order={2}>
          <Tooltip label={description} disabled={!description}>
            <Text span inherit>
              {label}
            </Text>
          </Tooltip>
        </Title>
        {actual !== null && weeklyWorkingMinutes && (
          <Text miw="10rem">
            {formatDuration((actual / 100) * weeklyWorkingMinutes)} per week
          </Text>
        )}
      </Stack>
      <RingProgress
        label={
          <Stack gap={0}>
            <Text c="brand" fw={700} ta="center" size="xl">
              {actual !== null ? `${actual}%` : "–"}
            </Text>
            {trend !== 0 && (
              <Group
                wrap="nowrap"
                gap={0}
                c={trend < 0 ? "secondary" : "brand"}
                justify="center"
              >
                {trend > 0 ? (
                  <IconArrowUpRight size="1em" />
                ) : (
                  <IconArrowDownLeft size="1em" />
                )}
                <Text inherit fz="xs">
                  {Math.abs(trend)}%
                </Text>
              </Group>
            )}
          </Stack>
        }
        sections={[{ value: actual ?? 0, color: "brand" }]}
      />
    </Group>
  );
}
