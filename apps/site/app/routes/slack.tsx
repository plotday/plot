import { useState } from "react";

import {
  Anchor,
  Button,
  Container,
  Group,
  List,
  Paper,
  Stack,
  Text,
  Title,
} from "@mantine/core";

import { IconBrandSlack, IconCheck, IconCopy } from "@tabler/icons-react";

import { mergeMeta } from "~/lib/meta";
import type { Route } from "./+types/slack";

export function meta(_: Route.MetaArgs) {
  return mergeMeta([
    { title: "Install Plot Sync for Slack" },
    {
      name: "description",
      content:
        "Unlock Plot Sync for your Slack workspace. Admins install once; members connect their own accounts.",
    },
  ]);
}

export async function loader({ context, request }: Route.LoaderArgs) {
  const url = new URL(request.url);
  return {
    apiUrl: context.cloudflare.env.API_ROOT || "https://api.plot.day",
    siteUrl: `${url.protocol}//${url.host}`,
  };
}

const ADMIN_REQUEST_MESSAGE = (siteUrl: string) =>
  `Hi — I'd like to connect Slack to Plot (plot.day), but our workspace requires admin approval to install apps. Could you install Plot Sync for our workspace? It's a one-time step that only requests team:read (workspace name/icon) and grants no access to messages, channels, or DMs. Once installed, each team member connects their own Slack individually inside Plot.\n\nInstall here: ${siteUrl}/slack`;

export default function SlackInstall({ loaderData }: Route.ComponentProps) {
  const { apiUrl, siteUrl } = loaderData;
  const [copied, setCopied] = useState(false);

  const handleCopy = async () => {
    try {
      await navigator.clipboard.writeText(ADMIN_REQUEST_MESSAGE(siteUrl));
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch {
      // Clipboard may be blocked; fall back to selecting the textarea below.
    }
  };

  return (
    <Container size="sm" mt="xl" mb="xl">
      <Stack gap="xl">
        <div>
          <Title order={1}>Install Plot Sync for Slack</Title>
          <Text c="dimmed" mt="sm">
            One-time install for your workspace. After it's done, anyone on
            your team can connect their own Slack account to Plot.
          </Text>
        </div>

        <Paper p="xl" radius="md" withBorder>
          <Stack gap="md">
            <Title order={2} size="h3">
              What this install does
            </Title>
            <Text>
              You're installing the Plot Sync app on your Slack workspace so
              that individual members can later authorize it for themselves.
              This single install step asks for one permission —{" "}
              <Text span fw={600}>
                team:read
              </Text>{" "}
              — so Plot can show the workspace name and icon.
            </Text>
            <Text fw={500} mt="xs">
              What we do <em>not</em> ask for in this step:
            </Text>
            <List size="sm">
              <List.Item>No access to messages, channels, or DMs.</List.Item>
              <List.Item>No ability to post on your behalf.</List.Item>
              <List.Item>
                No account linkage — we throw away the admin's token as soon as
                the install completes.
              </List.Item>
            </List>
            <Text size="sm" c="dimmed">
              Each member who wants to use Plot with Slack will later grant
              their own, narrower permissions from inside Plot.
            </Text>
          </Stack>
        </Paper>

        <Group justify="center">
          <Button
            size="lg"
            component="a"
            href={`${apiUrl}/slack/install`}
            leftSection={<IconBrandSlack size={20} />}
            color="#4A154B"
          >
            Add to Slack
          </Button>
        </Group>

        <Paper p="md" radius="md" withBorder>
          <Stack gap="sm">
            <Text size="sm">
              If admin approval is required in your workspace, send your admin
              this request:
            </Text>
            <Group gap="sm" wrap="nowrap">
              <Button
                variant="light"
                size="sm"
                leftSection={
                  copied ? <IconCheck size={16} /> : <IconCopy size={16} />
                }
                onClick={handleCopy}
              >
                {copied ? "Copied" : "Copy message"}
              </Button>
              <Text size="sm" c="dimmed">
                Includes a link to this page.
              </Text>
            </Group>
          </Stack>
        </Paper>

        <Text size="sm" c="dimmed" ta="center">
          Questions?{" "}
          <Anchor href="mailto:help@plot.day">help@plot.day</Anchor>
        </Text>
      </Stack>
    </Container>
  );
}
