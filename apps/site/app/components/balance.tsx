import { Fragment } from "react";

import { Box, Group, Slider, Stack, Text } from "@mantine/core";
import { useMediaQuery } from "@mantine/hooks";

import classes from "./balance.module.css";

const WEEKLY_HOURS = 96;

export const EVERYTHING_ELSE = [
  "Responding to email",
  "Keeping up with Slack",
  "Random interruptions",
  "Preparing PowerPoint presentations",
  "Daily check-ins",
  "Weekly check-ins",
  "Project kickoffs",
  "Cross-functional project syncs",
  "Project status review",
  "Project retrospectives",
  "Sprint planning",
  "Quarterly planning",
  "Annual planning",
  "Team meetings",
  "Department meetings",
  "Company all-hands meetings",
  "One-on-ones with your manager",
  "One-on-ones with you skip-level manager",
  "One-on-ones with your direct reports",
  "Writing project updates",
  "Reading project updates",
  "Metrics reviews",
  "Performance reviews",
  "Recurring zombie project status meetings no one has cancelled",
];

export const PRIORITIES = [
  "Propose a new project",
  "Delegate well",
  "Make steady progress on big projects",
  "Deep focus work",
  "Automate time-consuming tasks",
  "Learn a new technology",
  "Conduct user research",
  "Prioritize time for key relationships",
  "Consistent fitness for mental and physical health",
  "Review the performance of the latest launch",
  "Mentor someone to take on something new",
  "Thoughtfully prepare for a critical conversation",
  "Develop a new strategy",
  "Strengthen a key relationship",
  "Research industry trends",
  "Reflect, learn, and adapt",
  "Analyze customer data for new insights",
  "Get ahead of future crises",
  "Become an expert in competitor's products",
  "Include space to lead with calm",
];

function Activities({
  activities,
  color,
}: {
  activities: string[];
  color: any;
}) {
  const isSm = useMediaQuery("(max-width: 768px)");
  return (
    <Text
      ta={isSm ? "inherit" : "justify"}
      lineClamp={isSm ? 8 : 4}
      fz={isSm ? "sm" : "md"}
    >
      {activities.map((activity, i) => (
        <Fragment key={i}>
          {i > 0 && <> &sdot; </>}
          <Text span className={i % 2 ? color : classes.grayText}>
            {activity}
          </Text>
        </Fragment>
      ))}
    </Text>
  );
}

export function Balance({
  target,
  onChange,
}: {
  target: number;
  onChange: (value: number) => void;
}) {
  return (
    <Stack gap="md">
      <Group justify="space-between">
        <Text fz="xl" fw={700} c="brand">
          Priorities
        </Text>
        <Text fz="xl" fw={700} c="secondary">
          Everything Else
        </Text>
      </Group>
      <Slider
        color="brand"
        value={target}
        onChange={onChange}
        // label={(value) => `${value} hours per week`}
        label={null}
        max={WEEKLY_HOURS}
        step={0.5}
        marks={[
          { value: 8 },
          { value: 16 },
          { value: 24 },
          { value: 32 },
          { value: 40 },
          { value: 48 },
          { value: 56 },
          { value: 64 },
          { value: 72 },
          { value: 80 },
          { value: 88 },
          { value: 96 },
        ]}
        classNames={{
          track: classes.sliderTrack,
          thumb: classes.sliderThumb,
        }}
      />
      <Group mt="md" gap={0}>
        <Box
          w={`${(target / WEEKLY_HOURS) * 100}%`}
          pr={{ base: "sm", lg: "md" }}
          display={target > 1 ? "block" : "none"}
        >
          <Activities activities={PRIORITIES} color={classes.nonMeetingText} />
        </Box>
        <Box
          w={`${((WEEKLY_HOURS - target) / WEEKLY_HOURS) * 100}%`}
          pl={{ base: "sm", lg: "md" }}
          ta="right"
          style={{ overflow: "hidden" }}
          display={target < WEEKLY_HOURS - 1 ? "block" : "none"}
        >
          <Activities
            activities={EVERYTHING_ELSE}
            color={classes.meetingText}
          />
        </Box>
      </Group>
    </Stack>
  );
}
