import { RingProgress, Text } from "@mantine/core";

import { formatDuration } from "@plotday/tz";

export function Gauge({
  label,
  values,
}: {
  label: string;
  values: {
    count: number;
    minutes: number;
    value: string;
  }[];
}) {
  const colours = ["blue", "yellow", "cyan", "pink", "teal", "lime"];
  const total = values.reduce((total, value) => total + value.minutes, 0);
  return (
    <RingProgress
      size={170}
      thickness={16}
      label={
        <Text size="xs" ta="center" px="xs" style={{ pointerEvents: "none" }}>
          {label}
        </Text>
      }
      sections={values.map((value, i) => ({
        value: (value.minutes / total) * 100,
        tooltip: `${value.value} – ${formatDuration(value.minutes)}`,
        color: colours[i % colours.length],
      }))}
    />
  );
}
