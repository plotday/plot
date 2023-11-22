import { useCallback, useEffect, useState } from "react";

import { Group, Input, NumberInput } from "@mantine/core";

export function Duration({
  onChange,
  value,
  label,
}: {
  onChange: (minutes: number) => void;
  value: number;
  label?: string;
}) {
  const [hours, setHours] = useState<number>(Math.floor(value / 60));
  const [minutes, setMinutes] = useState<number>(Math.floor(value) % 60);

  const newValue =
    hours * 60 + minutes === value ? undefined : hours * 60 + minutes;
  useEffect(() => {
    if (newValue === undefined) return;
    onChange(newValue);
  }, [onChange, newValue]);

  const onHourChange = useCallback((value: number | string) => {
    if (typeof value === "string") {
      value = parseInt(value);
      if (isNaN(value)) return;
    }
    setHours(value);
  }, []);
  const onMinuteChange = useCallback((value: number | string) => {
    if (typeof value === "string") {
      value = parseInt(value);
      if (isNaN(value)) return;
    }
    if (value === 60) {
      setHours((h) => h + 1);
      setMinutes(0);
    } else if (value < 0) {
      setHours((h) => {
        if (h > 0) {
          setMinutes(60 + (value as number));
          return h - 1;
        }
        return h;
      });
    } else {
      setMinutes(value);
    }
  }, []);

  return (
    <Group gap="lg">
      <Input.Wrapper label={label}>
        <Group gap="xs">
          <NumberInput
            data-autofocus
            placeholder="hours"
            suffix={hours === 1 ? " hour" : " hours"}
            ta="right"
            w="6rem"
            value={hours}
            onChange={onHourChange}
            allowNegative={false}
            allowDecimal={false}
            styles={{ input: { textAlign: "right" } }}
            variant="unstyled"
            hideControls
          />
          <NumberInput
            placeholder="minutes"
            suffix=" minutes"
            w="7rem"
            prefix={minutes < 10 ? "0" : ""}
            value={minutes}
            onChange={onMinuteChange}
            allowNegative={false}
            allowDecimal={false}
            allowLeadingZeros
            min={-15}
            max={60}
            step={15}
            styles={{ input: { textAlign: "right" } }}
            variant="unstyled"
          />
        </Group>
      </Input.Wrapper>
    </Group>
  );
}
