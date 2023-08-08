import {
  Box,
  Button,
  Container,
  Group,
  Stack,
  Text,
  Title,
} from "@mantine/core";
import { useState } from "react";

import { Balance } from "../components/balance";
import classes from "./_public._index.module.css";

function Highlight({ children }: { children: React.ReactNode }) {
  return (
    <Text span inherit={true} variant="gradient">
      {children}
    </Text>
  );
}

export default function Index() {
  const [target, setTarget] = useState(16);

  return (
    <Stack gap={0}>
      <Container size="sm" pt={36} pb={36}>
        <div className={classes.inner}>
          <div className={classes.content}>
            <Title order={2} className={classes.title} mb="xl">
              <Highlight>Better </Highlight> than busy
            </Title>

            <Text>
              Plot is a calendar that{" "}
              <Highlight>reduces meeting overload</Highlight> so you can engage
              well while making progress on what moves you forward.
            </Text>

            <Group mt={32}>
              <Button
                radius="xl"
                size="md"
                className={classes.control}
                component="a"
                href="/sync"
              >
                Get started
              </Button>
            </Group>
          </div>
        </div>
      </Container>
      <Box pt="xl" pb="xl" mt="xl" mb={0} className={classes.graySection}>
        <Container size="xl">
          <Stack>
            <Title order={3} size="h1">
              What is your <Highlight>ideal</Highlight> work week?
            </Title>
            <Balance target={target} onChange={setTarget} />
            <Group mt="lg">
              <Button
                variant="outline"
                radius="xl"
                size="md"
                className={classes.control}
                component="a"
                href="/sync"
              >
                Compare with your calendar
              </Button>
            </Group>
          </Stack>
        </Container>
      </Box>
      <Box p="xl" className={classes.punchSection}>
        <Container size="sm">
          <Stack>
            <Title order={3} size="h1">
              Design your time
            </Title>
            <ul>
              <li>
                <b>Put meetings on a diet</b> &#8212; Reduce your meeting load
                by prioritizing meeting requests and applying alternatives that
                free up your time.
              </li>
              <li>
                <b>Always prepared, 100% follow-through</b> &#8212; Get full
                value from your meetings by efficiently and systematically
                processing your upcoming and recent meetings.
              </li>
              <li>
                <b>Track your progress</b> &#8212; Learn where you're spending
                your time and which actions will align your calendar with your
                priorities.
              </li>
            </ul>
            <Group mt="lg">
              <Button
                radius="xl"
                size="md"
                className={classes.control}
                component="a"
                href="/sync"
              >
                Get started
              </Button>
            </Group>
          </Stack>
        </Container>
      </Box>
    </Stack>
  );
}
