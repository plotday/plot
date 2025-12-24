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
            3. Choose Your Priorities
          </Title>
          <Text mb="sm">
            Priorities organize your activities into contexts where you can
            focus. Start with roles or areas of your life, such as work or
            school and add other such as health, social, volunteer roles, and
            personal development. Get the most out of Plot by nesting your
            priorities. For example, you probably mave multiple roles and
            projects at work (e.g. manager, project lead), and within each, you
            may have areas of focus (e.g. customer development, planning).
          </Text>
          <Text mb="sm">
            When you organize your priorities this way, you can zoom into a
            particular are to focus and zoom out to pick up everything else.
          </Text>
        </div>

        <div>
          <Title order={2} size="h3" mb="md">
            4. Create Activities
          </Title>
          <Text mb="sm">
            Activities are the building blocks of Plot. An activity can be:
          </Text>
          <List>
            <List.Item>An action you need to take</List.Item>
            <List.Item>
              Scheduled time, including events from your calendar
            </List.Item>
            <List.Item>
              Notes including links to documents and items from other apps
            </List.Item>
            <List.Item>Messages and updates from other apps</List.Item>
          </List>
          <Text mt="sm">
            Click the "+" button or use the command bar to create your first
            activity.
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
            Add twists to a priority to give them access to that priority and
            its descendants.
          </Text>
        </div>

        <div>
          <Title order={2} size="h3" mb="md">
            6. Start Working
          </Title>
          <Text>
            Choose a focus to see the context and actions you need to make
            progress on what matters. Plot works offline and syncs when you're
            connected, so you can work anywhere.
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
