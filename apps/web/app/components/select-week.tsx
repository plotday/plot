import { useSearchParams } from "@remix-run/react";

import { Button, Group, Text } from "@mantine/core";

import { IconChevronLeft, IconChevronRight } from "@tabler/icons-react";
import add from "date-fns/add";

import { formatDate, startOfWeek } from "@plotday/tz";

import { useTz } from "app/hooks";

export const getWeek = (params: URLSearchParams, tz: string) => {
  const startParam = params.get("week");
  let week;
  if (startParam) {
    week = startParam;
  } else {
    week = formatDate(startOfWeek(new Date(), tz), tz, "yyyy-MM-dd");
  }
  const start = startOfWeek(add(new Date(week), { days: 1 }), tz);
  const end = startOfWeek(add(new Date(week), { days: 8 }), tz);
  return { week, start, end };
};

export const SelectWeek = () => {
  const [searchParams, setSearchParams] = useSearchParams();
  const tz = useTz();
  const defaultWeek = startOfWeek(new Date(), tz);
  const weekParam = searchParams.get("week");
  const week = weekParam
    ? startOfWeek(add(new Date(weekParam), { days: 1 }), tz)
    : defaultWeek;
  let weekTitle;
  if (week === defaultWeek) {
    weekTitle = "This week";
  } else if (week.getTime() === add(defaultWeek, { days: 7 }).getTime()) {
    weekTitle = "Next week";
  } else if (week.getTime() === add(defaultWeek, { days: -7 }).getTime()) {
    weekTitle = "Last week";
  } else {
    weekTitle = formatDate(week, tz, "MMM d");
    weekTitle += " – ";
    if (
      formatDate(week, tz, "MMM") !==
      formatDate(add(week, { days: 6 }), tz, "MMM")
    ) {
      weekTitle += formatDate(add(week, { days: 6 }), tz, "MMM ");
    }
    weekTitle += formatDate(add(week, { days: 6 }), tz, "d");
  }
  const move = (movement: number) => {
    const newStart = add(week, { days: movement * 7 });
    setSearchParams((p) => {
      const { week: _week, ...other } = Object.fromEntries(p.entries());
      if (newStart.getTime() === defaultWeek.getTime()) return other;
      return {
        ...other,
        week: formatDate(newStart, tz, "yyyy-MM-dd"),
      };
    });
  };
  return (
    <Group gap={0} wrap="nowrap">
      <Button
        variant="subtle"
        radius={0}
        onClick={() => {
          move(-1);
        }}
      >
        <IconChevronLeft />
      </Button>
      <Text w="8em" ta="center" fz="sm" fw="bold">
        {weekTitle}
      </Text>
      <Button
        variant="subtle"
        radius={0}
        onClick={() => {
          move(1);
        }}
      >
        <IconChevronRight />
      </Button>
    </Group>
  );
};
