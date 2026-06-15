import { Anchor, Container, Stack, Text, Title } from "@mantine/core";
import { Link } from "react-router";

import type { Route } from "./+types/internal._index";
import { requireTeamMember } from "../lib/internal-auth.server";

export function meta(_: Route.MetaArgs) {
  return [
    { title: "Internal Docs | Plot" },
    { name: "robots", content: "noindex" },
  ];
}

export async function loader(args: Route.LoaderArgs) {
  const { email } = await requireTeamMember(args);
  return { email };
}

export default function InternalIndex({ loaderData }: Route.ComponentProps) {
  return (
    <Container mt="xl" size="sm">
      <Stack gap="md">
        <Title order={1}>Plot internal docs</Title>
        <Text c="dimmed">Signed in as {loaderData.email}</Text>
        <Anchor component={Link} to="/internal/features">
          Product features (marketing source catalog)
        </Anchor>
        <Anchor component={Link} to="/internal/voice">
          Voice &amp; tone (how Plot sounds)
        </Anchor>
        <Anchor component={Link} to="/internal/updates">
          Updates / changelog by release
        </Anchor>
        <Anchor component={Link} to="/internal/store-listings">
          App Store listings (iOS, macOS, Android, Windows)
        </Anchor>
      </Stack>
    </Container>
  );
}
