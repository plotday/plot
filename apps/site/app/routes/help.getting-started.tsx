import {
  Anchor,
  Breadcrumbs,
  Container,
  List,
  Stack,
  Text,
  Title,
} from "@mantine/core";

import type { Route } from "./+types/help.getting-started";

export function meta(_: Route.MetaArgs) {
  return [
    { title: "Getting Started | Plot Help" },
    { name: "description", content: "Learn how to get started with Plot" },
  ];
}

export default function GettingStarted() {
  return (
    <Container mt="lg" mb="xl">
      <Breadcrumbs mb="md">
        <Anchor href="/help">Help Center</Anchor>
        <Text>Getting Started</Text>
      </Breadcrumbs>

      <Stack gap="xl">
        <div>
          <Title order={1}>Getting Started with Plot</Title>
          <Text c="dimmed" mt="sm">
            Everything you need to know to start using Plot effectively
          </Text>
        </div>

        <div>
          <Title order={2} size="h3" mb="md">
            1. Download and Install Plot
          </Title>
          <Text mb="sm">Plot is available on multiple platforms:</Text>
          <List>
            <List.Item>
              <strong>Desktop:</strong> Install for macOS using the App Store or
              Windows using the Windows Store
            </List.Item>
            <List.Item>
              <strong>Mobile:</strong> Install from the App Store (iOS) or
              Google Play (Android)
            </List.Item>
            <List.Item>
              <strong>Web:</strong> Access Plot using a web browser at{" "}
              <Anchor href="https://plot.day" target="_blank">
                plot.day
              </Anchor>
            </List.Item>
          </List>
        </div>

        <div>
          <Title order={2} size="h3" mb="md">
            2. Create Your Account
          </Title>
          <Text mb="sm">
            Sign up with any account you want to use to sign into Plot. We
            recommend a personal account that you're have access to even if your
            job changes. You can sync data from any other account after signing
            in.
          </Text>
        </div>

        <div>
          <Title order={2} size="h3" mb="md">
            3. Choose Your Focuses
          </Title>
          <Text mb="sm">
            Focuses are the contexts your conversations and work get organized
            into — projects, relationships, and areas of responsibility. Start
            with the roles or areas of your life, such as work or school, and
            add others like health, social, volunteer roles, and personal
            development.
          </Text>
          <Text mb="sm">
            When you create a focus, Plot finds the conversations that belong
            there and keeps matching new ones automatically. Anything that isn't
            matched to a focus waits in your Inbox, and the Everything view
            brings it all together in one place.
          </Text>
        </div>

        <div>
          <Title order={2} size="h3" mb="md">
            4. Create Activities
          </Title>
          <Text>
            Activities are the things that flow through Plot: conversations from
            your connected tools (email, chat, project threads), scheduled
            events, tasks, and notes. New activities show up automatically from
            your connections; you can also create your own with the "+" button
            or the command bar.
          </Text>
        </div>

        <div>
          <Title order={2} size="h3" mb="md">
            5. Install Twists (Optional)
          </Title>
          <Text mb="sm">
            Twists are Plot's version of extensions or plugins. They add
            powerful integrations and workflows:
          </Text>
          <List>
            <List.Item>Connect your email, calendar, and other apps</List.Item>
            <List.Item>Automate repetitive tasks</List.Item>
            <List.Item>Customize Plot to fit your workflow</List.Item>
          </List>
          <Text mt="sm">
            Add twists to a focus to give them access to that focus.
          </Text>
        </div>

        <div>
          <Title order={2} size="h3" mb="md">
            6. Start Working
          </Title>
          <Text>
            Pick a focus to work on. Plot proposes a window to work through
            the conversations and work that belong there. Reply, add follow-ups,
            take notes — everything stays organized for next time. Outside the
            window, the rest of your day is yours.
          </Text>
        </div>

        <Text c="dimmed" mt="xl">
          Need more help? Check out our <Anchor href="/help/faqs">FAQs</Anchor>{" "}
          or <Anchor href="/help/contact">contact support</Anchor>.
        </Text>
      </Stack>
    </Container>
  );
}
