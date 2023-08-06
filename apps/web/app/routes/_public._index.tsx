import { Button, Container, Group, Text, Title } from "@mantine/core";

import { logout } from "../auth";
import { useSupabase, useUser } from "../root";

export default function Index() {
  const supabase = useSupabase();
  const user = useUser();
  return (
    <Container mt="xl" ml="xl">
      <Title>
        A <s>calendar</s> day ☀️ you'll love 💗
      </Title>
      {user && (
        <>
          <Text>{user.email}</Text>
          <Group mt="lg">
            <Button component="a" href="/sync">
              Sync
            </Button>
            <Button onClick={() => supabase && logout(supabase)}>
              Sign out
            </Button>
          </Group>
        </>
      )}
      {!user && (
        <Button mt="lg" component="a" href="/login">
          Sign in
        </Button>
      )}
    </Container>
  );
}
