import {
  Box,
  Center,
  RingProgress,
  Stack,
  Text,
  Title,
  Tooltip,
} from "@mantine/core";
import { useDisclosure } from "@mantine/hooks";

import {
  IconArrowDownLeft,
  IconArrowUpRight,
  IconEdit,
} from "@tabler/icons-react";

import { formatDuration } from "@plotday/tz";

import { TargetModal } from "./target-modal";

export function Gauge({
  label,
  description,
  actual,
  pending,
  trend,
  weeklyWorkingMinutes,
  target,
  onTargetChange,
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
  const total = Math.max(
    target ?? weeklyWorkingMinutes ?? 100,
    actual + pending
  );

  let good = actual;
  let bad = 0;
  let goodPending = pending;
  let badPending = 0;
  if (target !== undefined && !moreBetter) {
    good = Math.min(actual, target);
    bad = actual - good;
    goodPending = Math.min(pending, target - good);
    badPending = pending - goodPending;
  }

  const [opened, { open, close }] = useDisclosure(false);

  return (
    <>
      {onTargetChange && weeklyWorkingMinutes && (
        <TargetModal
          labelName={label}
          onTargetChange={onTargetChange}
          defaultTarget={actual}
          targetMinutes={target}
          opened={opened}
          close={close}
        />
      )}
      <Center>
        <Stack
          title={onTargetChange ? "Edit goal" : undefined}
          onClick={open}
          style={
            onTargetChange
              ? {
                  cursor: "pointer",
                }
              : {}
          }
        >
          <Box pos="relative">
            {onTargetChange && (
              <Box pos="absolute" bottom={0} left={40} c="brand" lh={0}>
                <IconEdit size="1rem" />
              </Box>
            )}
            {trend !== 0 && (
              <Box
                c={trend < 0 === !!moreBetter ? "secondary" : "brand"}
                pos="absolute"
                style={{
                  bottom: 0,
                  right: 36,
                }}
              >
                <Stack gap={2} align="center">
                  {trend > 0 ? (
                    <IconArrowUpRight size="0.9em" />
                  ) : (
                    <IconArrowDownLeft size="0.9em" />
                  )}

                  <Text
                    inherit
                    fz="xs"
                    lh={1}
                    c={trend < 0 === !!moreBetter ? "secondary" : "brand"}
                  >
                    {Math.abs(trend)}%
                  </Text>
                </Stack>
              </Box>
            )}
            <RingProgress
              size={260}
              label={
                <Stack gap={8} align="center">
                  {weeklyWorkingMinutes && (
                    <Text c="dimmed" fz="sm" lh={1}>
                      {target ? `Goal: ${formatDuration(target)}` : "per week"}
                    </Text>
                  )}
                  <Text
                    c={bad ? "secondary" : "brand"}
                    fw={700}
                    fz={32}
                    ta="center"
                    size="xl"
                    lh={1}
                  >
                    {!weeklyWorkingMinutes && (actual ? `${actual}%` : "–")}
                    {weeklyWorkingMinutes &&
                      actual !== 0 &&
                      formatDuration(actual)}
                  </Text>
                  <Title order={2} size="h4" ta="center" c="gray" lh={1}>
                    <Tooltip label={description} disabled={!description}>
                      <Text span inherit>
                        {label}
                      </Text>
                    </Tooltip>
                  </Title>
                </Stack>
              }
              sections={[
                { value: (good / total) * 50, color: "brand" },
                {
                  value: (bad / total) * 50,
                  color: "secondary",
                },
                {
                  value: (goodPending / total) * 50,
                  color: "var(--mantine-color-brand-background)",
                },
                {
                  value: (badPending / total) * 50,
                  color: "var(--mantine-color-secondary-background)",
                },
                {
                  value:
                    (1 - (good + bad + goodPending + badPending) / total) * 50,
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
          </Box>
        </Stack>
      </Center>
    </>
  );
}
