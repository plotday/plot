import { Box, Group, Slider, Stack, Text } from "@mantine/core";
import { useMediaQuery } from "@mantine/hooks";
import { Fragment } from "react";

import classes from "./balance.module.css";

const WEEKLY_HOURS = 40;

export const MEETING_ACTIVITIES = [
  "Team meeting",
  "Cross-functional project sync",
  "1:1 with your manager",
  "Sprint planning",
  "Quarterly business review",
  "Weekly check-in",
  "Department all-hands meeting",
  "1:1s with your direct reports",
  "Hiring committee",
  "Bug triage",
  "Design review",
  "Project status review",
  "Quarterly planning",
  "Project retrospective",
  "Brainstorming session",
  "1:1 with your skip-level manager",
  "Standup",
  "Budget planning meeting",
  "Launch review",
  "Candidate interview",
  "Executive reporting",
  "Incident postmortem",
  "Strategy discussion",
  "Performance review",
  "Onboarding session",
  "Metrics review",
  "Vendor evaluation",
  "Project kickoff",
  "Campaign planning",
  "Compliance training",
];

export const NON_MEETING_ACTIVITIES = [
  "Deep focus work",
  "Collaborate with colleagues on a project",
  "Prepare for a meeting to make it effective for all attendees",
  "Analyze customer data for new insights",
  "Review the performance of the latest launch",
  "Learn a new skill through a course",
  "Draft a proposal for a new project",
  "Perfect an executive presentation",
  "Research industry trends",
  "Review and respond to messages",
  "Prioritize and plan upcoming work",
  "Update project documentation",
  "Margins between meetings",
  "Prepare for a performance review",
  "Attend a team-building activity",
  "Brainstorm ideas for a new campaign",
  "Test new software or tools",
  "Attend a professional development workshop",
  "Hallway conversations",
  "Review and edit a colleague's work",
  "Prepare for a client presentation",
  "Provide feedback on a coworker's performance",
  "Develop a new strategy",
  "Mentor a colleague",
  "Conduct user research",
  "Create training materials",
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
    <Stack>
      <Group justify="space-between">
        <Text fz="xl" fw={700} c="orange">
          Meetings
        </Text>
        <Text fz="xl" fw={700} c="brand">
          Everything Else
        </Text>
      </Group>
      <Slider
        color="orange"
        value={target}
        onChange={onChange}
        label={(value) => `${value} hours of meetings per week`}
        max={WEEKLY_HOURS}
        step={0.5}
        marks={[
          { value: 10, label: "10" },
          { value: 20, label: "20" },
          { value: 30, label: "30" },
          { value: 40, label: "40" },
        ]}
        classNames={{
          track: classes.sliderTrack,
        }}
      />
      <Group mt="md" gap={0}>
        <Box
          w={`${(target / WEEKLY_HOURS) * 100}%`}
          pr={{ base: "sm", lg: "md" }}
          display={target > 0 ? "block" : "none"}
        >
          <Activities
            color={classes.meetingText}
            activities={MEETING_ACTIVITIES}
          />
        </Box>
        <Box
          w={`${((WEEKLY_HOURS - target) / WEEKLY_HOURS) * 100}%`}
          pl={{ base: "sm", lg: "md" }}
          ta="right"
          style={{ overflow: "hidden" }}
          display={target < WEEKLY_HOURS ? "block" : "none"}
        >
          <Activities
            color={classes.nonMeetingText}
            activities={NON_MEETING_ACTIVITIES}
          />
        </Box>
      </Group>
    </Stack>
  );
}
