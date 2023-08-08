import { Card, Container, Stack, Title } from "@mantine/core";
import type { LoaderArgs } from "@remix-run/cloudflare";
import { json } from "@remix-run/cloudflare";

import { getUser } from "../auth";
import CalendarSources from "../components/calendar-sources";
import { saveAuthCookie } from "../cookies.server";
import { createServerClient } from "../db";

export async function loader({ request, context }: LoaderArgs) {
  let response: Response | undefined;
  let supabase;
  ({ supabase, response } = createServerClient(request, context));

  let user = await getUser(supabase);
  if (!user) {
    return null;
  }

  saveAuthCookie(request, response);

  return json(null, {
    headers: response.headers,
  });
}

export default function Settings() {
  return (
    <Container size="xs" p="sm">
      <Card>
        <Stack>
          <Title order={2}>Add another calendar</Title>
          <CalendarSources />
        </Stack>
      </Card>
    </Container>
  );
}
