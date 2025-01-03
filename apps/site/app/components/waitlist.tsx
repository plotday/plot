import { Button, Group, TextInput } from "@mantine/core";

import { IconMail } from "@tabler/icons-react";
import { Form, useSearchParams } from "react-router";

export function WaitlistForm() {
  const [searchParams] = useSearchParams();
  const email = searchParams.get("email") || "";
  return (
    <Form method="post" action="/waitlist">
      <Group grow>
        <TextInput
          name="email"
          type="email"
          defaultValue={email}
          placeholder="Your work email"
          required
          leftSection={<IconMail size={16} />}
          maw="unset"
        />
        <Button type="submit" variant="gradient" maw="unset">
          Join the waitlist
        </Button>
      </Group>
    </Form>
  );
}
