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
              Plot is a workspace that organizes and prioritizes everything from
              all your apps. It's where you go to start your next most impactful
              action. Sometimes you'll complete it within Plot. Often you'll use
              Plot to jump straight into the right place in another app to work
              there.
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

          <Accordion.Item value="collaboration">
            <Accordion.Control>
              Is Plot for individuals or teams?
            </Accordion.Control>
            <Accordion.Panel>
              We've obsessed over creating a highly effective individual
              experience while building Plot from the ground up for team
              collaboration. Team support will be released soon.
            </Accordion.Panel>
          </Accordion.Item>

          <Accordion.Item value="pricing">
            <Accordion.Control>How much does Plot cost?</Accordion.Control>
            <Accordion.Panel>
              Plot is free to use for core collaboration features including
              unlimited people, conversations, and priorities. Premium Twist
              integrations and automations have pricing packages to fit every
              team.
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
