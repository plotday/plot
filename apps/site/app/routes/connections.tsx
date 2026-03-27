import { useCallback, useEffect, useMemo, useState } from "react";

import {
  Badge,
  Box,
  Button,
  Container,
  Flex,
  Stack,
  Text,
  TextInput,
  Title,
  useComputedColorScheme,
} from "@mantine/core";

import { IconArrowRight, IconSearch, IconThumbUp } from "@tabler/icons-react";
import { Link, useFetcher } from "react-router";

import { CATEGORIES, CONNECTIONS, type Connection } from "../data/connections";
import { mergeMeta } from "~/lib/meta";
import type { Route } from "./+types/connections";
import classes from "./connections.module.css";

const VOTED_KEY = "plot-connection-votes";

function getVotedNames(): string[] {
  if (typeof window === "undefined") return [];
  try {
    return JSON.parse(localStorage.getItem(VOTED_KEY) || "[]");
  } catch {
    return [];
  }
}

function addVotedName(name: string) {
  const voted = getVotedNames();
  if (!voted.includes(name)) {
    voted.push(name);
    localStorage.setItem(VOTED_KEY, JSON.stringify(voted));
  }
}

export async function loader({ context }: Route.LoaderArgs) {
  const kv = context.cloudflare.env.VOTES;
  const votes: Record<string, number> = {};

  if (kv) {
    const list = await kv.list({ prefix: "votes:" });
    if (list.keys.length > 0) {
      const entries = await Promise.all(
        list.keys.map(async (key: { name: string }) => {
          const val = await kv.get(key.name);
          return [
            key.name.replace("votes:", ""),
            parseInt(val || "0", 10),
          ] as const;
        }),
      );
      for (const [name, count] of entries) {
        votes[name] = count;
      }
    }
  }

  return { votes };
}

export async function action({ request, context }: Route.ActionArgs) {
  const kv = context.cloudflare.env.VOTES;
  if (!kv) {
    return { error: "Voting unavailable" };
  }

  const formData = await request.formData();
  const name = formData.get("name") as string;
  if (!name) {
    return { error: "Missing name" };
  }

  const key = `votes:${name}`;
  const current = parseInt((await kv.get(key)) || "0", 10);
  const newCount = current + 1;
  await kv.put(key, String(newCount));

  return { name, count: newCount };
}

export function meta(_: Route.MetaArgs) {
  return mergeMeta([
    { title: "Connections | Plot" },
    {
      name: "description",
      content:
        "Browse all Plot connections. Integrate your calendar, email, project tools, and more. Vote for the integrations you want next.",
    },
    { property: "og:title", content: "Plot Connections" },
    { property: "og:description", content: "Browse and vote for the integrations you want in Plot." },
  ]);
}

function ConnectionCard({
  connection,
  voteCount,
  hasVoted,
  onVote,
  isDark,
}: {
  connection: Connection;
  voteCount: number;
  hasVoted: boolean;
  onVote: (name: string) => void;
  isDark: boolean;
}) {
  const logoSrc =
    isDark && connection.logoDark ? connection.logoDark : connection.logo;
  return (
    <Box className={classes.connectionCard}>
      <img
        src={logoSrc}
        alt={connection.name}
        className={classes.connectionLogo}
        loading="lazy"
      />
      <Text fw={600} fz="sm">
        {connection.name}
      </Text>
      <Badge size="xs" variant="light" color="gray">
        {connection.category}
      </Badge>
      <Text className={classes.entities}>{connection.entities.join(", ")}</Text>
      {connection.available ? (
        <span className={classes.availableBadge}>Available</span>
      ) : hasVoted ? (
        <span className={classes.voteCount}>
          <IconThumbUp size={14} />
          {voteCount}
        </span>
      ) : (
        <button
          className={classes.voteButton}
          onClick={() => onVote(connection.name)}
          type="button"
        >
          <IconThumbUp size={14} />
          +1
          {voteCount > 0 && ` (${voteCount})`}
        </button>
      )}
    </Box>
  );
}

export default function Connections({ loaderData }: Route.ComponentProps) {
  const { votes } = loaderData;
  const fetcher = useFetcher();
  const colorScheme = useComputedColorScheme("light");
  const isDark = colorScheme === "dark";

  const [search, setSearch] = useState("");
  const [category, setCategory] = useState<string | null>(null);
  const [votedNames, setVotedNames] = useState<string[]>([]);
  const [optimisticVotes, setOptimisticVotes] = useState<
    Record<string, number>
  >({});

  useEffect(() => {
    setVotedNames(getVotedNames());
  }, []);

  const mergedVotes = useMemo(() => {
    return { ...votes, ...optimisticVotes };
  }, [votes, optimisticVotes]);

  const handleVote = useCallback(
    (name: string) => {
      addVotedName(name);
      setVotedNames((prev) => [...prev, name]);

      const currentCount = mergedVotes[name] || 0;
      setOptimisticVotes((prev) => ({ ...prev, [name]: currentCount + 1 }));

      fetcher.submit({ name }, { method: "POST" });
    },
    [fetcher, mergedVotes],
  );

  const filtered = useMemo(() => {
    let items = CONNECTIONS;

    if (search) {
      const q = search.toLowerCase();
      items = items.filter(
        (c) =>
          c.name.toLowerCase().includes(q) ||
          c.category.toLowerCase().includes(q) ||
          c.entities.some((e) => e.toLowerCase().includes(q)),
      );
    }

    if (category) {
      items = items.filter((c) => c.category === category);
    }

    // Sort: available first, then by vote count desc, then alphabetically
    return [...items].sort((a, b) => {
      if (a.available !== b.available) return a.available ? -1 : 1;
      const aVotes = mergedVotes[a.name] || 0;
      const bVotes = mergedVotes[b.name] || 0;
      if (aVotes !== bVotes) return bVotes - aVotes;
      return a.name.localeCompare(b.name);
    });
  }, [search, category, mergedVotes]);

  return (
    <Stack gap={0}>
      {/* Hero */}
      <Box className={classes.heroSection} pt={60} pb={60}>
        <Container size="md">
          <Stack align="center" gap="lg" ta="center">
            <Title order={1} className={classes.heroTitle}>
              <Text span inherit variant="gradient">
                Connections
              </Text>
            </Title>
            <Text className={classes.heroSubtext}>
              Plot connects to the tools you already use.
              <br />
              Browse available integrations and vote for the ones you want next.
            </Text>
          </Stack>
        </Container>
      </Box>

      {/* Filter + Grid */}
      <Box className={classes.graySection} pt={40} pb={80}>
        <Container size="lg">
          <Stack gap="xl">
            {/* Filters */}
            <Stack gap="md" align="center">
              <TextInput
                placeholder="Search connections..."
                leftSection={<IconSearch size={16} />}
                value={search}
                onChange={(e) => setSearch(e.currentTarget.value)}
                w={{ base: "100%", sm: 360 }}
              />
              <Box className={classes.categoryChips}>
                <Badge
                  variant={category === null ? "filled" : "light"}
                  color={category === null ? "brand" : "gray"}
                  style={{ cursor: "pointer" }}
                  onClick={() => setCategory(null)}
                >
                  All
                </Badge>
                {CATEGORIES.map((cat) => (
                  <Badge
                    key={cat}
                    variant={category === cat ? "filled" : "light"}
                    color={category === cat ? "brand" : "gray"}
                    style={{ cursor: "pointer" }}
                    onClick={() => setCategory(cat)}
                  >
                    {cat}
                  </Badge>
                ))}
              </Box>
            </Stack>

            {/* Grid */}
            <Box className={classes.connectionGrid}>
              {filtered.map((connection) => (
                <ConnectionCard
                  key={connection.name}
                  connection={connection}
                  voteCount={mergedVotes[connection.name] || 0}
                  hasVoted={votedNames.includes(connection.name)}
                  onVote={handleVote}
                  isDark={isDark}
                />
              ))}
            </Box>

            {filtered.length === 0 && (
              <Text ta="center" c="dimmed" py="xl">
                No connections found. Try a different search or category.
              </Text>
            )}
          </Stack>
        </Container>
      </Box>

      {/* CTA */}
      <Box className={classes.ctaSection} pt={80} pb={80}>
        <Container size="sm">
          <Stack gap="lg" align="center" ta="center">
            <Title order={2} size="h2" className={classes.ctaTitle}>
              Don't see what you need?
            </Title>
            <Text c="rgba(255,255,255,0.85)" fz="lg">
              Build your own custom connector, or let us know what you'd like to
              see.
            </Text>
            <Flex gap="md" wrap="wrap" justify="center">
              <Button
                variant="white"
                size="lg"
                component="a"
                href="https://twist.plot.day/"
                rightSection={<IconArrowRight size={18} />}
              >
                Build a Custom Connector
              </Button>
              <Button
                variant="outline"
                size="lg"
                color="white"
                component={Link}
                to="/start"
              >
                Get started free
              </Button>
            </Flex>
          </Stack>
        </Container>
      </Box>
    </Stack>
  );
}
