import {
  Center,
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
  pending,
  trend,
  weeklyWorkingMinutes,
  moreBetter,
}: {
  label: string;
  description?: string;
  weeklyWorkingMinutes?: number;
  actual: number | null;
  pending?: number;
  trend?: number;
  target?: number;
  onTargetChange?: (target: number | null) => void;
  moreBetter?: boolean;
}) {
  actual = Math.round(actual ?? 0);
  pending = Math.round(pending ?? 0);
  trend = Math.round(trend ?? 0);
  moreBetter = moreBetter !== false;

  return (
    <Center>
      <Stack>
        <RingProgress
          size={250}
          label={
            <Stack gap="xs" align="center">
              <Group gap={8}>
                <Tooltip
                  label={`${formatDuration(
                    (actual / 100) * (weeklyWorkingMinutes ?? 0)
                  )} per week`}
                  disabled={!actual || !weeklyWorkingMinutes}
                >
                  <Text c="brand" fw={700} fz={32} ta="center" size="xl" lh={1}>
                    {actual ? `${actual}%` : "–"}
                  </Text>
                </Tooltip>
                {trend !== 0 && (
                  <Stack
                    c={trend < 0 === !!moreBetter ? "secondary" : "brand"}
                    align="center"
                    gap={2}
                  >
                    {trend > 0 ? (
                      <IconArrowUpRight size="0.9em" />
                    ) : (
                      <IconArrowDownLeft size="0.9em" />
                    )}
                    <Text inherit fz="xs" lh={1}>
                      {Math.abs(trend)}%
                    </Text>
                  </Stack>
                )}
              </Group>
              <Title order={2} size="h4" ta="center" c="gray">
                <Tooltip label={description} disabled={!description}>
                  <Text span inherit>
                    {label}
                  </Text>
                </Tooltip>
              </Title>
            </Stack>
          }
          sections={[
            { value: actual / 2, color: "brand" },
            {
              value: pending ? pending / 2 : 0,
              color: "var(--mantine-color-brand-background)",
            },
            {
              value: 50 - (actual + pending) / 2,
              color: "var(--mantine-color-track)",
            },
          ]}
          rootColor="#ffffff00"
          styles={{
            root: {
              transform: "rotate(-90deg)",
              width: "calc(var(--rp-size)/2)",
              marginBottom: "calc(-1 * var(--rp-size) / 2)",
            },
            label: {
              transform: "rotate(90deg)",
              left: "var(--rp-label-offset)",
              top: "var(--rp-label-offset)",
              bottom: "var(--rp-label-offset)",
              right: "var(--rp-label-offset)",
              paddingBottom:
                "calc(var(--rp-size) / 2 - var(--rp-label-offset) )",
              display: "flex",
              alignItems: "flex-end",
              justifyContent: "center",
            },
          }}
        />
      </Stack>
    </Center>
  );
}
