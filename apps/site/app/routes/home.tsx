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

import {
  IconCheck,
  IconHierarchy2,
  IconInbox,
  IconMessages,
  IconPuzzle,
} from "@tabler/icons-react";
import { Link } from "react-router";

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
                Your best work, every day
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
            <div className={`${classes.storyImageWrap} ${STORY_TABS[activeTab].lightVignette ? classes.storyImageLightVignette : ""}`}>
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

      {/* Benefit 1 — Everything in one place */}
      <Box className={classes.whiteSection} pt={80} pb={80}>
        <Container size="lg">
          <Box className={classes.benefitSection}>
            <Stack className={classes.benefitText} gap="md">
              <Title order={2} size="h2" className={classes.sectionTitle}>
                Everything in one place, ready for action
              </Title>
              <Text className={classes.sectionBody}>
                Tasks, messages, events, notes, and links live
                together—organized by priority, not arrival time. Plot pulls
                work from Google Calendar, Slack, Linear, Gmail, and more.
                Related items collect into threads. Smart notifications surface
                what actually needs your attention. Nothing falls through the
                cracks.
              </Text>
              <Button
                className={classes.benefitCta}
                variant="subtle"
                component={Link}
                to="/start"
              >
                Try Plot →
              </Button>
            </Stack>
            <Box className={classes.benefitPlaceholder}>
              <div className={classes.benefitPlaceholderInner}>
                <IconInbox
                  size={56}
                  className={classes.benefitPlaceholderIcon}
                />
                <Text className={classes.benefitPlaceholderLabel}>
                  Unified activity view
                </Text>
                <Text className={classes.benefitPlaceholderHint}>
                  Screenshot coming soon
                </Text>
              </div>
            </Box>
          </Box>
        </Container>
      </Box>

      {/* Benefit 2 — Structure without overhead */}
      <Box className={classes.graySection} pt={80} pb={80}>
        <Container size="lg">
          <Box
            className={`${classes.benefitSection} ${classes.benefitReverse}`}
          >
            <Stack className={classes.benefitText} gap="md">
              <Title order={2} size="h2" className={classes.sectionTitle}>
                Structure without the overhead
              </Title>
              <Text className={classes.sectionBody}>
                Organize work the way you think—by project, client, team, or
                life area. Priorities nest as deep as you need and reorder with
                a drag. No boards to configure, no fields to fill out. Changes
                in your calendar or issue tracker show up automatically. Add a
                tag when it helps. Skip the ceremony when it doesn't.
              </Text>
              <Button
                className={classes.benefitCta}
                variant="subtle"
                component={Link}
                to="/start"
              >
                Try Plot →
              </Button>
            </Stack>
            <Box className={classes.benefitPlaceholder}>
              <div className={classes.benefitPlaceholderInner}>
                <IconHierarchy2
                  size={56}
                  className={classes.benefitPlaceholderIcon}
                />
                <Text className={classes.benefitPlaceholderLabel}>
                  Nested priorities
                </Text>
                <Text className={classes.benefitPlaceholderHint}>
                  Screenshot coming soon
                </Text>
              </div>
            </Box>
          </Box>
        </Container>
      </Box>

      {/* Benefit 3 — Collaboration without noise */}
      <Box className={classes.whiteSection} pt={80} pb={80}>
        <Container size="lg">
          <Box className={classes.benefitSection}>
            <Stack className={classes.benefitText} gap="md">
              <Title order={2} size="h2" className={classes.sectionTitle}>
                Collaboration without the noise
              </Title>
              <Text className={classes.sectionBody}>
                Conversations happen on the work they're about. Notes, messages,
                and links stay threaded on the activity they belong to—not
                buried in a scrolling feed. Everyone sees what's relevant with
                their own unread tracking. Share priorities with your team, keep
                what's private to yourself, and never send a "just checking in"
                message again.
              </Text>
              <Button
                className={classes.benefitCta}
                variant="subtle"
                component={Link}
                to="/start"
              >
                Try Plot →
              </Button>
            </Stack>
            <Box className={classes.benefitPlaceholder}>
              <div className={classes.benefitPlaceholderInner}>
                <IconMessages
                  size={56}
                  className={classes.benefitPlaceholderIcon}
                />
                <Text className={classes.benefitPlaceholderLabel}>
                  Threaded conversations
                </Text>
                <Text className={classes.benefitPlaceholderHint}>
                  Screenshot coming soon
                </Text>
              </div>
            </Box>
          </Box>
        </Container>
      </Box>

      {/* Benefit 4 — A platform for your work */}
      <Box className={classes.graySection} pt={80} pb={80}>
        <Container size="lg">
          <Box
            className={`${classes.benefitSection} ${classes.benefitReverse}`}
          >
            <Stack className={classes.benefitText} gap="md">
              <Title order={2} size="h2" className={classes.sectionTitle}>
                A platform for how your work actually works
              </Title>
              <Text className={classes.sectionBody}>
                Twists are extensions that add capabilities to Plot—automations,
                integrations, and custom workflows that run securely inside your
                workspace. Chat with Claude, ChatGPT, and Gemini right where
                your work lives. Install twists built by others or create your
                own with Plot's open SDK. Because twists have access to your
                connections and your work context, they can answer questions
                like "What did we decide about X?" with real information.
              </Text>
              <Button
                className={classes.benefitCta}
                variant="subtle"
                component={Link}
                to="/start"
              >
                Try Plot →
              </Button>
            </Stack>
            <Box className={classes.benefitPlaceholder}>
              <div className={classes.benefitPlaceholderInner}>
                <IconPuzzle
                  size={56}
                  className={classes.benefitPlaceholderIcon}
                />
                <Text className={classes.benefitPlaceholderLabel}>
                  Twists & AI chat
                </Text>
                <Text className={classes.benefitPlaceholderHint}>
                  Screenshot coming soon
                </Text>
              </div>
            </Box>
          </Box>
        </Container>
      </Box>

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
