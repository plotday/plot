import { Container, Stack, Text } from "@mantine/core";
import { SignIn } from "@clerk/react-router";
import { useSearchParams } from "react-router";

import type { Route } from "./+types/signin";

export function meta(_: Route.MetaArgs) {
  return [
    {
      title: "Sign In | Plot",
    },
  ];
}

export default function SignInPage() {
  const [searchParams] = useSearchParams();
  const returnTo = searchParams.get("returnTo") || "/";

  return (
    <Container size="xs" mt="xl">
      <Stack gap="md" align="center">
        <SignIn fallbackRedirectUrl={returnTo} />

        <Text size="sm" c="dimmed" ta="center">
          By signing in, you agree to our <a href="/terms">Terms of Service</a>{" "}
          and <a href="/privacy">Privacy Policy</a>.
        </Text>
      </Stack>
    </Container>
  );
}
