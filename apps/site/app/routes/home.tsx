import { useState } from "react";

import {
  Box,
  Button,
  Container,
  Flex,
  Stack,
  Text,
  Title,
} from "@mantine/core";

import { IconCheck } from "@tabler/icons-react";
import { Link } from "react-router";

import { BenefitSection } from "~/components/home/BenefitSection";
import { FeaturesStrip } from "~/components/home/FeaturesStrip";
import { PlatformCallout } from "~/components/home/PlatformCallout";
import type { Route } from "./+types/home";
import classes from "./home.module.css";

const STORY_TABS = [
  {
    label: "Email",
    image: "/assets/email.png",
    title: "A to-do list written by others",
    copy: "Email lets us easily pass work to others. But when inboxes drive our day, we spend it playing the inbox zero game. Once we \"win\", we often realize we haven't started on what's most important.",
    lightVignette: true,
  },
  {
    label: "Team Chat",
    image: "/assets/chat.png",
    title: "Fast coordination, slow resolution",
    copy: "Chat makes coordination nearly free — a question doesn't need to wait for a meeting, and anyone can weigh in. But the loudest threads are often the least important, while the essential ones quietly go unresolved.",
    lightVignette: true,
  },
  {
    label: "Project Management",
    image: "/assets/project.png",
    title: "Clarity that becomes its own overhead",
    copy: "Project management tools bring clarity to work. But when nothing moves without a ticket, the tool becomes the bottleneck. Maintaining it becomes its own job, and planning starts taking longer than the work.",
    lightVignette: true,
  },
  {
    label: "Meetings",
    image: "/assets/meetings.png",
    title: "High bandwidth, high cost",
    copy: "Meetings offer high-bandwidth collaboration that can solve challenges that snarl email threads. But when nothing can happen without a meeting, we live by our calendars and burn our best energy before the work begins.",
    lightVignette: false,
  },
];

export function meta(_: Route.MetaArgs) {
  return [
    { title: "Plot | Your best work, every day" },
    {
      name: "description",
      content:
        "Everything in one place. Organized, prioritized, and ready for action.",
    },
    { "og:image": "https://plot.day/assets/p.png" },
    { "twitter:title": "Plot" },
    { "twitter:description": "Your best work, every day" },
    { "twitter:image": "https://plot.day/assets/p.png" },
  ];
}

export default function Home() {
  const [activeTab, setActiveTab] = useState(0);

  return (
    <Stack gap={0}>
      {/* Hero */}
      <Box className={classes.heroSection} pt={60} pb={60}>
        <Container size="md">
          <Stack align="center" gap="lg" ta="center">
            <Title order={1} className={classes.heroTitle}>
              <Text span inherit variant="gradient">
                Your best work, every&nbsp;day
              </Text>
            </Title>
            <Text className={classes.heroSubtext}>
              Everything in one place.
              <br />
              Organized, prioritized, and ready for action.
            </Text>
            <Flex gap="md" wrap="wrap" justify="center">
              <Button variant="gradient" size="lg" component={Link} to="/start">
                Get started free
              </Button>
              <Button
                variant="subtle"
                size="lg"
                component="a"
                href="#story"
                onClick={(e: React.MouseEvent<HTMLAnchorElement>) => {
                  e.preventDefault();
                  document
                    .getElementById("story")
                    ?.scrollIntoView({ behavior: "smooth" });
                }}
              >
                Learn more &darr;
              </Button>
            </Flex>
          </Stack>
        </Container>
        <Container size="lg" mt="xl">
          <div className={classes.heroScreenshotWrap}>
            <picture>
              <source
                srcSet="/assets/screenshot-d.png"
                media="(prefers-color-scheme: dark)"
              />
              <img
                src="/assets/screenshot.png"
                alt="Plot interface showing a team conversation transforming into a prioritized action item"
                className={classes.heroScreenshot}
              />
            </picture>
          </div>
        </Container>
      </Box>

      {/* Productivity Story Tabs */}
      <Box id="story" className={classes.storySection} pt={80} pb={80}>
        <Container size="lg">
          <Title
            order={2}
            size="h2"
            className={classes.sectionTitle}
            ta="center"
            mb="xl"
          >
            So what's stopping us?
          </Title>
          <Box className={classes.storyLayout}>
            <div className={classes.storyTabs}>
              {STORY_TABS.map((tab, i) => (
                <button
                  key={tab.label}
                  className={`${classes.storyTab} ${i === activeTab ? classes.storyTabActive : ""}`}
                  onClick={() => setActiveTab(i)}
                  type="button"
                >
                  {tab.label}
                </button>
              ))}
            </div>
            <div
              className={`${classes.storyImageWrap} ${STORY_TABS[activeTab].lightVignette ? classes.storyImageLightVignette : ""}`}
            >
              <img
                src={STORY_TABS[activeTab].image}
                alt={STORY_TABS[activeTab].label}
                className={classes.storyImage}
              />
            </div>
            <div>
              <div className={classes.storyCopyTitle}>
                {STORY_TABS[activeTab].title}
              </div>
              <Text className={classes.storyCopy}>
                {STORY_TABS[activeTab].copy}
              </Text>
            </div>
          </Box>
        </Container>
        <Container size="md" mt={60}>
          <Text className={classes.hingeText}>
            Each one solves a real problem.
            <br />
            Unchecked, they can crowd out our best work.
          </Text>
        </Container>
      </Box>

      <Box id="benefits" />
      <BenefitSection
        title="Everything in one place"
        body="Your meeting gets a thread. Your task gets a note. Your email gets context. Plot pulls work from Google Calendar, Slack, Linear, Gmail, and more — organized by priority, not arrival time. Related items collect automatically. Smart notifications surface what actually needs your attention. Nothing falls through the cracks."
        screenshotLabel="Unified activity view"
      />
      <BenefitSection
        title="Ready for action"
        body={'Your agenda is your day — and Plot makes sure it\'s ready when you are. See everything due today across every tool, in one place. Open an item and find the notes, messages, and context already there. No tab-switching, no hunting for links, no "let me find that thread."'}
        screenshotLabel="Your agenda, your day"
        reverse
        background="gray"
      />
      <BenefitSection
        title="Momentum on what matters"
        body="Most tools break down at the boundary between planning and doing. Plot closes that gap. Zoom out to see your priorities and what's moving. Zoom in to focus on the work in front of you. Everything you need — context, collaborators, next steps — is already in the same place you do the work."
        screenshotLabel="Zoom in, zoom out"
      />
      <FeaturesStrip />
      <PlatformCallout />

      {/* Closing CTA */}
      <Box className={classes.ctaSection} pt={80} pb={80}>
        <Container size="sm">
          <Stack gap="lg" align="center" ta="center">
            <Title order={2} size="h2" className={classes.ctaTitle}>
              Get back to your best work.
            </Title>
            <Button variant="white" size="xl" component={Link} to="/start">
              Try Plot
            </Button>
            <Flex gap="lg" wrap="wrap" justify="center">
              <Flex align="center" gap={6}>
                <IconCheck size={14} color="rgba(255,255,255,0.8)" />
                <Text className={classes.trustItem}>
                  Mac, Windows, iOS, Android, and web
                </Text>
              </Flex>
            </Flex>
          </Stack>
        </Container>
      </Box>
    </Stack>
  );
}
