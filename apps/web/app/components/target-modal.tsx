import { useCallback, useEffect, useState } from "react";

import {
  Button,
  Group,
  Input,
  Modal,
  NumberInput,
  Stack,
  Text,
} from "@mantine/core";

export function TargetModal({
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
                styles={{ input: { textAlign: "right" } }}
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
