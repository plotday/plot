import type { ActionArgs, LoaderArgs } from "@remix-run/cloudflare";
import { redirect } from "@remix-run/cloudflare";
import { Form, useActionData } from "@remix-run/react";

import {
  Button,
  Card,
  Container,
  Group,
  Stack,
  Text,
  TextInput,
  Title,
} from "@mantine/core";

import { getUserId } from "app/auth";
import { saveCookie } from "app/cookies.server";
import { createServerAdminClient, createServerClient, safeQuery } from "app/db";

export async function action({ request, context }: ActionArgs) {
  const body = await request.formData();
  const code = body.get("code")?.toString();
  if (!code) return new Response("Code required", { status: 400 });

  const supabaseAdmin = createServerAdminClient(context);
  const match = safeQuery(
    await supabaseAdmin
      .from("invitation")
      .select()
      .eq("code", code)
      .maybeSingle()
  );
  if (!match) return new Response("Invalid code", { status: 400 });

  const response = new Response();
  saveCookie(response, "invitation", code);
  return redirect("/sync", {
    status: 303,
    headers: response.headers,
  });
}

export const loader = async ({ context, request }: LoaderArgs) => {
  let response: Response | undefined;
  let supabase;
  ({ supabase, response } = createServerClient(request, context));
  const user = await getUserId(supabase);

  if (!user) {
    return redirect("/login", {
      status: 303,
      headers: response.headers,
    });
  }

  return response;
};

export default function LoginCode() {
  const error = useActionData();
  return (
    <Container size="xs" p="sm" mt="xl">
      <Card>
        <Stack>
          <Title>Hello!</Title>
          <Text>
            Plot is currently in private, early access. If you have an
            invitation code, please enter it here.
          </Text>
          <Form method="post">
            <Group grow align="start">
              <TextInput
                name="code"
                type="text"
                error={error}
                placeholder="Invitation code"
                required
                maw="unset"
              />
              <Button type="submit" variant="outline">
                Continue
              </Button>
            </Group>
          </Form>
        </Stack>
      </Card>
    </Container>
  );
}
