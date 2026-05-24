import {
  Accordion,
  Anchor,
  Breadcrumbs,
  Container,
  Stack,
  Text,
  Title,
} from "@mantine/core";

import type { Route } from "./+types/help.faqs";

export function meta(_: Route.MetaArgs) {
  return [
    { title: "FAQs | Plot Help" },
    { name: "description", content: "Frequently asked questions about Plot" },
  ];
}

export default function FAQs() {
  return (
    <Container mt="lg" mb="xl">
      <Breadcrumbs mb="md">
        <Anchor href="/help">Help Center</Anchor>
        <Text>FAQs</Text>
      </Breadcrumbs>

      <Stack gap="xl">
        <div>
          <Title order={1}>Frequently Asked Questions</Title>
          <Text c="dimmed" mt="sm">
            Common questions about Plot features and functionality
          </Text>
        </div>

        <Accordion variant="separated">
          <Accordion.Item value="what-is-plot">
            <Accordion.Control>What is Plot?</Accordion.Control>
            <Accordion.Panel>
              Plot is a unified workspace for collaboration. It pulls together
              every conversation that needs a thoughtful reply — email, team
              chat, and threads inside the tools you use, like Linear and Docs —
              and organizes them by the projects, relationships, and areas they
              belong to. You stay on top of the people you work with without
              losing the rest of your day to your inbox.
            </Accordion.Panel>
          </Accordion.Item>

          <Accordion.Item value="platforms">
            <Accordion.Control>
              What platforms does Plot support?
            </Accordion.Control>
            <Accordion.Panel>
              Plot is available on:
              <ul style={{ marginTop: "0.5rem", marginBottom: 0 }}>
                <li>Desktop: macOS (App Store) and Windows (Windows Store)</li>
                <li>Mobile: iOS (App Store) and Android (Google Play)</li>
                <li>
                  Web browsers: <a href="https://plot.day">plot.day</a>
                </li>
              </ul>
              All platforms sync seamlessly, so you can switch between devices
              without losing your place. We recommend the desktop and mobile
              apps when possible for the best experience.
            </Accordion.Panel>
          </Accordion.Item>

          <Accordion.Item value="offline-sync">
            <Accordion.Control>Does Plot work offline?</Accordion.Control>
            <Accordion.Panel>
              Yes! Plot is local-first, which means it works without an internet
              connection. Your data is stored locally on your device and syncs
              to the cloud when you have an internet connection. This ensures
              you can always access and work with your data, even when offline.
            </Accordion.Panel>
          </Accordion.Item>

          <Accordion.Item value="twists">
            <Accordion.Control>What are Twists?</Accordion.Control>
            <Accordion.Panel>
              Twists are Plot's version of extensions. They extend Plot's
              functionality with integrations and automate workflows. You can
              install twists created by Plot, build your own using the Twist
              Creator (Twister), or use twists published by other users. Twists
              are added to a priority where they have access to only that
              priority.
            </Accordion.Panel>
          </Accordion.Item>

          <Accordion.Item value="calendar-todos">
            <Accordion.Control>
              What about my calendar and to-dos?
            </Accordion.Control>
            <Accordion.Panel>
              They're still here. Plot includes scheduled events and tasks
              alongside the conversations they relate to — agenda, priority
              tree, and Pomodoro timer included. They just take a back seat to
              keeping up with the people you work with.
            </Accordion.Panel>
          </Accordion.Item>

          <Accordion.Item value="collaboration">
            <Accordion.Control>
              Is Plot for individuals or teams?
            </Accordion.Control>
            <Accordion.Panel>
              Both. Plot is built for teams from the ground up, with no per-seat
              fees. It works just as well if you only connect your own accounts
              — you'll still see every conversation that needs you, organized
              and prioritized. Either way, nothing slips, and you keep moving on
              the work only you can do.
            </Accordion.Panel>
          </Accordion.Item>

          <Accordion.Item value="pricing">
            <Accordion.Control>How much does Plot cost?</Accordion.Control>
            <Accordion.Panel>
              Plot is free to use, including unlimited teammates. You only pay
              for the connections that bring your conversations together. See
              the <Anchor href="/pricing">pricing page</Anchor> for details.
            </Accordion.Panel>
          </Accordion.Item>

          <Accordion.Item value="data-security">
            <Accordion.Control>Is my data secure?</Accordion.Control>
            <Accordion.Panel>
              Yes. Your data is stored securely and synced to a remote database
              for backup and multi-device sync. We take data privacy and
              security seriously. For more details, please review our{" "}
              <Anchor href="/privacy">Privacy Policy</Anchor>.
            </Accordion.Panel>
          </Accordion.Item>
        </Accordion>

        <Text c="dimmed" mt="md">
          Can't find what you're looking for?{" "}
          <Anchor href="/help/contact">Contact us</Anchor> for help.
        </Text>
      </Stack>
    </Container>
  );
}
