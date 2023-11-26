import { useCallback, useState } from "react";

import { useFetcher } from "@remix-run/react";

import { Box, Button, Group, Menu, Progress } from "@mantine/core";

import {
  IconMinus,
  IconPlus,
  IconTrendingDown,
  IconTrendingUp,
} from "@tabler/icons-react";

import type { Database } from "@plotday/db";
import { pathToUrl } from "@plotday/db";
import { formatDuration } from "@plotday/tz";

type Category = Database["public"]["Tables"]["category"]["Row"];

export const WeeklyGoal = ({
  category,
  insights,
  relativeWidth = 100,
}: {
  category: Category;
  insights?: { [type: string]: { minutes: number } };
  relativeWidth?: number;
}) => {
  const [budget, setBudget] = useState(category?.budget_weekly ?? 0);
  const [minimize, setMinimize] = useState(category?.minimize ?? false);
  const fetcher = useFetcher();
  const fetcherSubmit = fetcher.submit;
  if (isNaN(relativeWidth)) relativeWidth = 0;

  const scheduled =
    (insights?.meeting?.minutes ?? 0) + (insights?.task?.minutes ?? 0);

  const good = Math.min(scheduled, budget);
  const bad = Math.max(scheduled - budget, 0);
  const remaining = Math.max(budget - scheduled, 0);
  const total = good + bad + remaining;

  const saveMinimize = useCallback(
    (value: boolean) => {
      if (!category?.id) return;
      let path = category.path as string;
      if (path.indexOf(".") === -1) path = `${path}.other`;
      setMinimize(value);
      fetcherSubmit(
        {
          id: category.id,
          minimize: value,
        },
        { method: "PATCH", action: pathToUrl(path) }
      );
    },
    [category, fetcherSubmit]
  );
  const saveBudget = useCallback(
    (change: number) => {
      if (!category?.id) return;
      let path = category.path as string;
      if (path.indexOf(".") === -1) path = `${path}.other`;
      setBudget((value) => {
        value = Math.max(0, value + change);
        fetcherSubmit(
          {
            id: category.id,
            budget_weekly: value,
          },
          { method: "PATCH", action: pathToUrl(path) }
        );
        return value;
      });
    },
    [category, fetcherSubmit]
  );

  return (
    <Group>
      <Button.Group>
        <Menu shadow="md" width={200}>
          <Menu.Target>
            <Button variant="subtle" size="xs">
              {minimize ? (
                <IconTrendingDown size={16} />
              ) : (
                <IconTrendingUp size={16} />
              )}
            </Button>
          </Menu.Target>

          <Menu.Dropdown>
            <Menu.Item
              leftSection={<IconTrendingDown size={16} />}
              onClick={() => saveMinimize(true)}
            >
              Budget
            </Menu.Item>
            <Menu.Item
              leftSection={<IconTrendingUp size={16} />}
              onClick={() => saveMinimize(false)}
            >
              Goal
            </Menu.Item>
          </Menu.Dropdown>
        </Menu>
        <Button variant="subtle" size="xs" onClick={() => saveBudget(-15)}>
          <IconMinus size={16} />
        </Button>
        <Button variant="subtle" size="xs" onClick={() => saveBudget(15)}>
          <IconPlus size={16} />
        </Button>
      </Button.Group>
      <Box style={{ flexGrow: 1 }}>
        <Box w={`${relativeWidth}%`}>
          <Progress.Root size={18}>
            {good > 0 && (
              <Progress.Section value={(good / total) * 100} color="brand">
                <Progress.Label c="var(--mantine-color-default)" lh="unset">
                  {formatDuration(good)}
                </Progress.Label>
              </Progress.Section>
            )}
            {bad > 0 && (
              <Progress.Section value={(bad / total) * 100} color="secondary">
                <Progress.Label c="var(--mantine-color-default)" lh="unset">
                  {formatDuration(bad)}
                </Progress.Label>
              </Progress.Section>
            )}
            {remaining > 0 && (
              <Progress.Section
                value={(remaining / total) * 100}
                color="var(--mantine-color-track)"
              >
                <Progress.Label c="var(--mantine-color-text)" lh="unset">
                  {formatDuration(remaining)}
                </Progress.Label>
              </Progress.Section>
            )}
          </Progress.Root>
        </Box>
      </Box>
    </Group>
  );
};

export default WeeklyGoal;
