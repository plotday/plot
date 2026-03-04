import {
  Box,
  Button,
  Container,
  Flex,
  SimpleGrid,
  Stack,
  Text,
  Title,
} from "@mantine/core";

import {
  IconArrowRight,
  IconCode,
  IconPlugConnected,
  IconRefresh,
  IconSparkles,
} from "@tabler/icons-react";
import { Link } from "react-router";

import type { Route } from "./+types/twists";
import classes from "./twists.module.css";

const PRODUCT_ICONS: { name: string; color: string; path: string }[] = [
  {
    name: "Google Calendar",
    color: "#4285F4",
    path: "M18.316 5.684H24v12.632h-5.684V5.684zM5.684 24h12.632v-5.684H5.684V24zM18.316 5.684V0H1.895A1.894 1.894 0 0 0 0 1.895v16.421h5.684V5.684h12.632zm-7.207 6.25v-.065c.272-.144.5-.349.687-.617s.279-.595.279-.982c0-.379-.099-.72-.3-1.025a2.05 2.05 0 0 0-.832-.714 2.703 2.703 0 0 0-1.197-.257c-.6 0-1.094.156-1.481.467-.386.311-.65.671-.793 1.078l1.085.452c.086-.249.224-.461.413-.633.189-.172.445-.257.767-.257.33 0 .602.088.816.264a.86.86 0 0 1 .322.703c0 .33-.12.589-.36.778-.24.19-.535.284-.886.284h-.567v1.085h.633c.407 0 .748.109 1.02.327.272.218.407.499.407.843 0 .336-.129.614-.387.832s-.565.327-.924.327c-.351 0-.651-.103-.897-.311-.248-.208-.422-.502-.521-.881l-1.096.452c.178.616.505 1.082.977 1.401.472.319.984.478 1.538.477a2.84 2.84 0 0 0 1.293-.291c.382-.193.684-.458.902-.794.218-.336.327-.72.327-1.149 0-.429-.115-.797-.344-1.105a2.067 2.067 0 0 0-.881-.689zm2.093-1.931l.602.913L15 10.045v5.744h1.187V8.446h-.827l-2.158 1.557zM22.105 0h-3.289v5.184H24V1.895A1.894 1.894 0 0 0 22.105 0zm-3.289 23.5l4.684-4.684h-4.684V23.5zM0 22.105C0 23.152.848 24 1.895 24h3.289v-5.184H0v3.289z",
  },
  {
    name: "Gmail",
    color: "#EA4335",
    path: "M24 5.457v13.909c0 .904-.732 1.636-1.636 1.636h-3.819V11.73L12 16.64l-6.545-4.91v9.273H1.636A1.636 1.636 0 0 1 0 19.366V5.457c0-2.023 2.309-3.178 3.927-1.964L5.455 4.64 12 9.548l6.545-4.91 1.528-1.145C21.69 2.28 24 3.434 24 5.457z",
  },
  {
    name: "Outlook",
    color: "#0078D4",
    path: "M7.88 12.04q0 .45-.11.87-.1.41-.33.74-.22.33-.58.52-.37.2-.87.2t-.85-.2q-.35-.21-.57-.55-.22-.33-.33-.75-.1-.42-.1-.86t.1-.87q.1-.43.34-.76.22-.34.59-.54.36-.2.87-.2t.86.2q.35.21.57.55.22.34.31.77.1.43.1.88zM24 12v9.38q0 .46-.33.8-.33.32-.8.32H7.13q-.46 0-.8-.33-.32-.33-.32-.8V18H1q-.41 0-.7-.3-.3-.29-.3-.7V7q0-.41.3-.7Q.58 6 1 6h6.5V2.55q0-.44.3-.75.3-.3.75-.3h12.9q.44 0 .75.3.3.3.3.75V10.85l1.24.72h.01q.1.07.18.18.07.12.07.25zm-6-8.25v3h3v-3zm0 4.5v3h3v-3zm0 4.5v1.83l3.05-1.83zm-5.25-9v3h3.75v-3zm0 4.5v3h3.75v-3zm0 4.5v2.03l2.41 1.5 1.34-.8v-2.73zM9 3.75V6h2l.13.01.12.04v-2.3zM5.98 15.98q.9 0 1.6-.3.7-.32 1.19-.86.48-.55.73-1.28.25-.74.25-1.61 0-.83-.25-1.55-.24-.71-.71-1.24t-1.15-.83q-.68-.3-1.55-.3-.92 0-1.64.3-.71.3-1.2.85-.5.54-.75 1.3-.25.74-.25 1.63 0 .85.26 1.56.26.72.74 1.23.48.52 1.17.81.69.3 1.56.3zM7.5 21h12.39L12 16.08V17q0 .41-.3.7-.29.3-.7.3H7.5zm15-.13v-7.24l-5.9 3.54Z",
  },
  {
    name: "Slack",
    color: "#4A154B",
    path: "M5.042 15.165a2.528 2.528 0 0 1-2.52 2.523A2.528 2.528 0 0 1 0 15.165a2.527 2.527 0 0 1 2.522-2.52h2.52v2.52zM6.313 15.165a2.527 2.527 0 0 1 2.521-2.52 2.527 2.527 0 0 1 2.521 2.52v6.313A2.528 2.528 0 0 1 8.834 24a2.528 2.528 0 0 1-2.521-2.522v-6.313zM8.834 5.042a2.528 2.528 0 0 1-2.521-2.52A2.528 2.528 0 0 1 8.834 0a2.528 2.528 0 0 1 2.521 2.522v2.52H8.834zM8.834 6.313a2.528 2.528 0 0 1 2.521 2.521 2.528 2.528 0 0 1-2.521 2.521H2.522A2.528 2.528 0 0 1 0 8.834a2.528 2.528 0 0 1 2.522-2.521h6.312zM18.956 8.834a2.528 2.528 0 0 1 2.522-2.521A2.528 2.528 0 0 1 24 8.834a2.528 2.528 0 0 1-2.522 2.521h-2.522V8.834zM17.688 8.834a2.528 2.528 0 0 1-2.523 2.521 2.527 2.527 0 0 1-2.52-2.521V2.522A2.527 2.527 0 0 1 15.165 0a2.528 2.528 0 0 1 2.523 2.522v6.312zM15.165 18.956a2.528 2.528 0 0 1 2.523 2.522A2.528 2.528 0 0 1 15.165 24a2.527 2.527 0 0 1-2.52-2.522v-2.522h2.52zM15.165 17.688a2.527 2.527 0 0 1-2.52-2.523 2.526 2.526 0 0 1 2.52-2.52h6.313A2.527 2.527 0 0 1 24 15.165a2.528 2.528 0 0 1-2.522 2.523h-6.313z",
  },
  {
    name: "MS Teams",
    color: "#6264A7",
    path: "M20.625 8.127q-.55 0-1.025-.205-.475-.205-.832-.563-.358-.357-.563-.832Q18 6.053 18 5.502q0-.54.205-1.02t.563-.837q.357-.358.832-.563.474-.205 1.025-.205.54 0 1.02.205t.837.563q.358.357.563.837.205.48.205 1.02 0 .55-.205 1.025-.205.475-.563.832-.357.358-.837.563-.48.205-1.02.205zm0-3.75q-.469 0-.797.328-.328.328-.328.797 0 .469.328.797.328.328.797.328.469 0 .797-.328.328-.328.328-.797 0-.469-.328-.797-.328-.328-.797-.328zM24 10.002v5.578q0 .774-.293 1.46-.293.685-.803 1.194-.51.51-1.195.803-.686.293-1.459.293-.445 0-.908-.105-.463-.106-.85-.329-.293.95-.855 1.729-.563.78-1.319 1.336-.756.557-1.67.861-.914.305-1.898.305-1.148 0-2.162-.398-1.014-.399-1.805-1.102-.79-.703-1.312-1.664t-.674-2.086h-5.8q-.411 0-.704-.293T0 16.881V6.873q0-.41.293-.703t.703-.293h8.59q-.34-.715-.34-1.5 0-.727.275-1.365.276-.639.75-1.114.475-.474 1.114-.75.638-.275 1.365-.275t1.365.275q.639.276 1.114.75.474.475.75 1.114.275.638.275 1.365t-.275 1.365q-.276.639-.75 1.113-.475.475-1.114.75-.638.276-1.365.276-.188 0-.375-.024-.188-.023-.375-.058v1.078h10.875q.469 0 .797.328.328.328.328.797zM12.75 2.373q-.41 0-.78.158-.368.158-.638.434-.27.275-.428.639-.158.363-.158.773 0 .41.158.78.159.368.428.638.27.27.639.428.369.158.779.158.41 0 .773-.158.364-.159.64-.428.274-.27.433-.639.158-.369.158-.779 0-.41-.158-.773-.159-.364-.434-.64-.275-.275-.639-.433-.363-.158-.773-.158zM6.937 9.814h2.25V7.94H2.814v1.875h2.25v6h1.875zm10.313 7.313v-6.75H12v6.504q0 .41-.293.703t-.703.293H8.309q.152.809.556 1.5.405.691.985 1.19.58.497 1.318.779.738.281 1.582.281.926 0 1.746-.352.82-.351 1.436-.966.615-.616.966-1.43.352-.815.352-1.752zm5.25-1.547v-5.203h-3.75v6.855q.305.305.691.452.387.146.809.146.469 0 .879-.176.41-.175.715-.48.304-.305.48-.715t.176-.879Z",
  },
  {
    name: "Linear",
    color: "#5E6AD2",
    path: "M2.886 4.18A11.982 11.982 0 0 1 11.99 0C18.624 0 24 5.376 24 12.009c0 3.64-1.62 6.903-4.18 9.105L2.887 4.18ZM1.817 5.626l16.556 16.556c-.524.33-1.075.62-1.65.866L.951 7.277c.247-.575.537-1.126.866-1.65ZM.322 9.163l14.515 14.515c-.71.172-1.443.282-2.195.322L0 11.358a12 12 0 0 1 .322-2.195Zm-.17 4.862 9.823 9.824a12.02 12.02 0 0 1-9.824-9.824Z",
  },
  {
    name: "Jira",
    color: "#0052CC",
    path: "M11.571 11.513H0a5.218 5.218 0 0 0 5.232 5.215h2.13v2.057A5.215 5.215 0 0 0 12.575 24V12.518a1.005 1.005 0 0 0-1.005-1.005zm5.723-5.756H5.736a5.215 5.215 0 0 0 5.215 5.214h2.129v2.058a5.218 5.218 0 0 0 5.215 5.214V6.758a1.001 1.001 0 0 0-1.001-1.001zM23.013 0H11.455a5.215 5.215 0 0 0 5.215 5.215h2.129v2.057A5.215 5.215 0 0 0 24 12.483V1.005A1.001 1.001 0 0 0 23.013 0Z",
  },
  {
    name: "Asana",
    color: "#F06A6A",
    path: "M18.78 12.653c-2.882 0-5.22 2.336-5.22 5.22s2.338 5.22 5.22 5.22 5.22-2.34 5.22-5.22-2.336-5.22-5.22-5.22zm-13.56 0c-2.88 0-5.22 2.337-5.22 5.22s2.338 5.22 5.22 5.22 5.22-2.338 5.22-5.22-2.336-5.22-5.22-5.22zm12-6.525c0 2.883-2.337 5.22-5.22 5.22-2.882 0-5.22-2.337-5.22-5.22 0-2.88 2.338-5.22 5.22-5.22 2.883 0 5.22 2.34 5.22 5.22z",
  },
];

export function meta(_: Route.MetaArgs) {
  return [
    { title: "Twists | Plot" },
    {
      name: "description",
      content:
        "Plot Twists bring your work from every app together, organized and prioritized. Integrations, automations, and custom workflows.",
    },
    { "og:title": "Plot Twists" },
    {
      "og:description":
        "Bring your work from every app together with Plot Twists.",
    },
    { "og:image": "https://plot.day/assets/p.png" },
    { "twitter:title": "Plot Twists" },
    {
      "twitter:description":
        "Bring your work from every app together with Plot Twists.",
    },
    { "twitter:image": "https://plot.day/assets/p.png" },
  ];
}

export default function Twists() {
  return (
    <Stack gap={0}>
      {/* Hero */}
      <Box className={classes.heroSection} pt={60} pb={60}>
        <Container size="md">
          <Stack align="center" gap="lg" ta="center">
            <Title order={1} className={classes.heroTitle}>
              <Text span inherit variant="gradient">
                Always have what you need to be productive
              </Text>
            </Title>
            <Text className={classes.heroSubtext}>
              Your work doesn't live in one app—it's scattered across email,
              calendars, project tools, documents, and AI assistants. Plot
              Twists automatically bring everything together, organized and
              prioritized exactly where you need it.
            </Text>
            <Button
              variant="gradient"
              size="lg"
              component={Link}
              to="/start"
            >
              Get started free
            </Button>
          </Stack>
        </Container>
      </Box>

      {/* Integrations */}
      <Box className={classes.graySection} pt={80} pb={80}>
        <Container size="lg">
          <Stack gap="xl" align="center">
            <Stack gap="md" ta="center" maw={700} mx="auto">
              <Title order={2} size="h2" className={classes.sectionTitle}>
                Connect the apps you already use
              </Title>
              <Text className={classes.sectionBody}>
                Plot Twists integrate with the tools your team relies on every
                day. Your calendar events, emails, tasks, and messages flow into
                Plot automatically—no manual updating required.
              </Text>
            </Stack>
            <Box className={classes.integrationGrid} maw={600}>
              {PRODUCT_ICONS.map(({ name, color, path }) => (
                <Box key={name} className={classes.integrationTile}>
                  <svg
                    className={classes.integrationIcon}
                    viewBox="0 0 24 24"
                    fill={color}
                    role="img"
                    aria-label={name}
                  >
                    <path d={path} />
                  </svg>
                  <Text fz="xs" fw={500} c="dimmed">
                    {name}
                  </Text>
                </Box>
              ))}
            </Box>
          </Stack>
        </Container>
      </Box>

      {/* How Twists Work */}
      <Box className={classes.whiteSection} pt={80} pb={80}>
        <Container size="lg">
          <Stack gap="xl">
            <Stack gap="md" ta="center" maw={700} mx="auto">
              <Title order={2} size="h2" className={classes.sectionTitle}>
                How Twists work
              </Title>
              <Text className={classes.sectionBody}>
                No more jumping between apps. No more manually updating your
                to-do list. No more wondering if you missed something important.
              </Text>
            </Stack>
            <SimpleGrid cols={{ base: 1, md: 3 }} spacing="lg">
              <Stack className={classes.card} gap="md">
                <Flex c="brand">
                  <IconPlugConnected size={32} />
                </Flex>
                <Title order={3} size="h4">
                  Bring it all together
                </Title>
                <Text className={classes.sectionBody} fz="sm">
                  Enable pre-built integrations for the apps you use. Your
                  calendar events, emails, tasks, and messages sync into Plot
                  automatically.
                </Text>
              </Stack>
              <Stack className={classes.card} gap="md">
                <Flex c="brand">
                  <IconSparkles size={32} />
                </Flex>
                <Title order={3} size="h4">
                  Organized and prioritized
                </Title>
                <Text className={classes.sectionBody} fz="sm">
                  Twists don't just dump data into Plot. They organize and
                  prioritize your work so you always know what matters most and
                  what needs your attention.
                </Text>
              </Stack>
              <Stack className={classes.card} gap="md">
                <Flex c="brand">
                  <IconRefresh size={32} />
                </Flex>
                <Title order={3} size="h4">
                  Two-way sync
                </Title>
                <Text className={classes.sectionBody} fz="sm">
                  Changes flow both ways. Update a task in Plot and it updates
                  in Linear. Reply in Plot and it posts to Slack. Work where you
                  want, stay in sync everywhere.
                </Text>
              </Stack>
            </SimpleGrid>
          </Stack>
        </Container>
      </Box>

      {/* Build Twists */}
      <Box className={classes.graySection} pt={80} pb={80}>
        <Container size="md">
          <Stack
            className={classes.buildSection}
            gap="md"
            align="center"
            ta="center"
          >
            <Flex c="brand">
              <IconCode size={40} />
            </Flex>
            <Title order={2} size="h3" className={classes.sectionTitle}>
              Build your own Twists
            </Title>
            <Text className={classes.sectionBody}>
              Twists are easy to build. Create custom integrations and
              automations that work exactly how your team needs. The Twist
              Creator SDK gives you everything you need to get started.
            </Text>
            <Button
              variant="outline"
              size="lg"
              component="a"
              href="https://twist.plot.day/"
              rightSection={<IconArrowRight size={18} />}
            >
              Twist Creator docs
            </Button>
          </Stack>
        </Container>
      </Box>

      {/* Final CTA */}
      <Box className={classes.ctaSection} pt={80} pb={80}>
        <Container size="sm">
          <Stack gap="lg" align="center" ta="center">
            <Title order={2} size="h2" className={classes.ctaTitle}>
              Stop juggling apps. Start making progress.
            </Title>
            <Text c="rgba(255,255,255,0.85)" fz="lg">
              Plot Twists eliminate the busywork of managing your productivity
              systems so you can focus on actual work.
            </Text>
            <Flex gap="md" wrap="wrap" justify="center">
              <Button
                variant="white"
                size="xl"
                component={Link}
                to="/start"
              >
                Get started free
              </Button>
              <Button
                variant="outline"
                size="xl"
                color="white"
                component={Link}
                to="/pricing"
              >
                See pricing
              </Button>
            </Flex>
          </Stack>
        </Container>
      </Box>
    </Stack>
  );
}
