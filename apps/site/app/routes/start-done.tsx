import { Button, Container, Stack, Text, Title } from "@mantine/core";

import { Link } from "react-router";

export default function Soon() {
  return (
    <Container size="xs">
      <Stack m={24} mt={0}>
        <Title order={2}>Let's do this!</Title>
        <Text>We'll be in touch soon to let you know the next steps.</Text>
        <Button variant="outline" component={Link} to="/" w="100%">
          Return Home
        </Button>
      </Stack>
    </Container>
  );
}
