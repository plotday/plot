import {
  Anchor,
  Breadcrumbs,
  Container,
  Paper,
  Stack,
  Text,
  Title,
} from "@mantine/core";

import type { Route } from "./+types/help.contact";

export function meta(_: Route.MetaArgs) {
  return [
    { title: "Contact Us | Plot Help" },
    { name: "description", content: "Get in touch with us" },
  ];
}

export default function Contact() {
  return (
    <Container mt="lg" mb="xl">
      <Breadcrumbs mb="md">
        <Anchor href="/help">Help Center</Anchor>
        <Text>Contact Us</Text>
      </Breadcrumbs>

      <Stack gap="xl">
        <div>
          <Title order={1}>Contact Us</Title>
          <Text c="dimmed" mt="sm">
            Get in touch with us
          </Text>
        </div>

        <Paper p="xl" radius="md" withBorder>
          <Stack gap="md">
            <div>
              <Title order={2} size="h3" mb="xs">
                Email Support
              </Title>
              <Text>
                We're here to help! Send us an email and we'll get back to you
                as soon as possible.
              </Text>
            </div>

            <div>
              <Text size="sm" fw={500} c="dimmed" mb={4}>
                Support Email
              </Text>
              <Text size="lg">
                <Anchor href="mailto:team@plot.day">help@plot.day</Anchor>
              </Text>
            </div>

            <div>
              <Text size="sm" fw={500} c="dimmed" mb={4}>
                General Inquiries
              </Text>
              <Text size="lg">
                <Anchor href="mailto:info@plot.day">info@plot.day</Anchor>
              </Text>
            </div>
          </Stack>
        </Paper>

        <div>
          <Title order={2} size="h4" mb="md">
            Before You Reach Out
          </Title>
          <Text mb="sm">
            To get help quickly, please check if your question is answered here:
          </Text>
          <Stack gap="xs">
            <Text>
              • Review our{" "}
              <Anchor href="/help/getting-started">Getting Started</Anchor>{" "}
              guide
            </Text>
            <Text>
              • Check the <Anchor href="/help/faqs">FAQs</Anchor> for common
              questions
            </Text>
            <Text>
              • Read our <Anchor href="/terms">Terms of Use</Anchor> and{" "}
              <Anchor href="/privacy">Privacy Policy</Anchor>
            </Text>
          </Stack>
        </div>

        <div>
          <Title order={2} size="h4" mb="md">
            When Contacting Us
          </Title>
          <Text>Please include as much detail as possible:</Text>
          <Stack gap="xs" mt="sm">
            <Text>• What you were trying to do</Text>
            <Text>• What happened instead</Text>
            <Text>
              • The platform you're using (Web, macOS, Windows, iOS, or Android)
            </Text>
            <Text>• Any error messages you received</Text>
          </Stack>
        </div>

        <Paper p="md" bg="blue.0" radius="md">
          <Text size="sm" c="dimmed">
            <strong>Note:</strong> We typically respond within 1-2 business
            days.
          </Text>
        </Paper>
      </Stack>
    </Container>
  );
}
