import { Anchor, Text } from "@mantine/core";
import { Link } from "@remix-run/react";

export default function Consent() {
  return (
    <Text c="dimmed">
      By continuing, you agree to the{" "}
      <Anchor component={Link} to={`/terms`}>
        Terms of Service
      </Anchor>{" "}
      and{" "}
      <Anchor component={Link} to={`/privacy`}>
        Privacy Policy
      </Anchor>
      .
    </Text>
  );
}
