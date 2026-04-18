import { useState } from "react";
import { Form, redirect } from "react-router";

import {
  Alert,
  Button,
  Container,
  Radio,
  Stack,
  Text,
  Title,
} from "@mantine/core";

import { mergeMeta } from "~/lib/meta";
import type { Route } from "./+types/unsubscribe";

type Frequency = "daily" | "weekly" | "never";

export function meta(_: Route.MetaArgs) {
  return mergeMeta([
    { title: "Email preferences | Plot" },
    { name: "robots", content: "noindex" },
  ]);
}

export async function loader({ request, context }: Route.LoaderArgs) {
  const url = new URL(request.url);
  const token = url.searchParams.get("t")?.trim() || null;
  const saved = url.searchParams.get("saved") as Frequency | null;
  return {
    token,
    saved,
    apiUrl: context.cloudflare.env.API_ROOT || "https://api.plot.day",
  };
}

export async function action({ request, context }: Route.ActionArgs) {
  const formData = await request.formData();
  const token = String(formData.get("token") ?? "").trim();
  const frequency = String(formData.get("frequency") ?? "") as Frequency;

  if (!token) {
    return { error: "Missing unsubscribe token." };
  }
  if (!["daily", "weekly", "never"].includes(frequency)) {
    return { error: "Please choose an option." };
  }

  const apiUrl = context.cloudflare.env.API_ROOT || "https://api.plot.day";
  const response = await fetch(`${apiUrl}/unsubscribe`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ token, frequency }),
  });

  if (!response.ok) {
    const body = (await response.json().catch(() => ({}))) as {
      error?: string;
    };
    return { error: body.error || "We couldn't update your preferences." };
  }

  const params = new URLSearchParams({ t: token, saved: frequency });
  throw redirect(`/unsubscribe?${params.toString()}`);
}

const OPTIONS: Array<{ value: Frequency; label: string; description: string }> =
  [
    {
      value: "daily",
      label: "At most once per day",
      description: "Get a single digest when there is new activity.",
    },
    {
      value: "weekly",
      label: "At most once per week",
      description: "A quieter weekly recap of anything you've missed.",
    },
    {
      value: "never",
      label: "Never",
      description: "Stop sending notification emails entirely.",
    },
  ];

const SAVED_LABEL: Record<Frequency, string> = {
  daily: "at most once per day",
  weekly: "at most once per week",
  never: "never",
};

export default function Unsubscribe({
  loaderData,
  actionData,
}: Route.ComponentProps) {
  const { token, saved } = loaderData;
  const error = actionData?.error;
  const [selected, setSelected] = useState<Frequency>(saved ?? "weekly");

  if (!token) {
    return (
      <Container size="sm" mt="xl">
        <Stack gap="md">
          <Title order={2}>Email preferences</Title>
          <Alert color="red" title="Missing link">
            This unsubscribe link is incomplete. Please open the link from your
            most recent Plot email, or contact{" "}
            <a href="mailto:team@plot.day">team@plot.day</a> for help.
          </Alert>
        </Stack>
      </Container>
    );
  }

  return (
    <Container size="sm" mt="xl">
      <Stack gap="md">
        <Title order={2}>Email preferences</Title>
        <Text>
          Plot only sends emails when there is activity in Plot and you haven't
          logged in recently. Choose how often you'd like to hear from us.
        </Text>

        {saved && (
          <Alert color="green" title="Saved">
            We'll email you {SAVED_LABEL[saved]}.
          </Alert>
        )}

        {error && (
          <Alert color="red" title="Something went wrong">
            {error}
          </Alert>
        )}

        <Form method="post">
          <input type="hidden" name="token" value={token} />
          <Stack gap="sm">
            {OPTIONS.map((option) => (
              <Radio
                key={option.value}
                name="frequency"
                value={option.value}
                checked={selected === option.value}
                onChange={() => setSelected(option.value)}
                label={option.label}
                description={option.description}
              />
            ))}
            <Button type="submit" mt="sm">
              Save preference
            </Button>
          </Stack>
        </Form>
      </Stack>
    </Container>
  );
}
