import { useState } from "react";

import {
  Accordion,
  Badge,
  Box,
  Button,
  Container,
  SegmentedControl,
  Stack,
  Text,
  Title,
} from "@mantine/core";

import { IconCheck } from "@tabler/icons-react";
import { Link } from "react-router";

import { PLANS } from "~/lib/plans";
import type { Billing } from "~/lib/plans";
import { mergeMeta } from "~/lib/meta";
import type { Route } from "./+types/pricing";
import classes from "./pricing.module.css";

const FAQS = [
  {
    question: "Why no per-seat pricing?",
    answer:
      "Per-seat pricing penalizes collaboration — it makes you think twice about adding a teammate. Plot is built around the idea that everyone involved should be working together, so we never charge per person. Bringing a teammate into a conversation should be free. You pay for connections, which reflect the actual complexity of your business.",
  },
  {
    question: "What counts as a connection?",
    answer:
      "A connection is one account linked to Plot via OAuth — for example, one Slack user in one workspace, one Google Calendar account, or one Linear account. Each sign-in counts as one connection, and you get access to everything within that account (all calendars, all projects, all channels). If two people on your team each connect their own Slack account, that's two connections.",
  },
  {
    question: "What happens if I hit my connection limit?",
    answer:
      "On the Free plan, you'll be prompted to upgrade to Core or Pro. On Core, you can upgrade to Pro for unlimited connections. On Team plans, you can add another group of 50 connections at any time. On annual plans, additional groups are prorated for the rest of your billing cycle.",
  },
  {
    question: "How far back does Plot import from my connected services?",
    answer:
      "When you first connect a service, Plot imports recent items — 1 week on Free, 30 days on Core, and 1 year on Pro and Team. After that, all new updates sync in real-time regardless of your plan. Everything already in Plot stays forever — the limit only applies to the initial import from external services. If you upgrade, we automatically import the additional history.",
  },
  {
    question: "Can I try Plot before committing to a paid plan?",
    answer:
      "Yes. Start with the Free plan — it includes unlimited collaborators and full search and history, so you (or your team) can experience Plot together. When you're ready for more connections or twists, upgrade anytime.",
  },
  {
    question: "What's a twist?",
    answer:
      "Twists are optional extensions that add capabilities to Plot — automations, AI agents, and custom workflows. Install twists published by others, or build your own. All twists run securely within Plot. Twists that use AI incur token costs, billed at cost or covered by your own API keys.",
  },
  {
    question: "How does AI pricing work?",
    answer:
      "Plot includes AI features like smart search, auto-tagging, and summaries. On the Free plan, these features are available with monthly usage limits. Paid plans include unlimited AI processing. When you install twists that use AI, you pay for the tokens consumed — at cost, with no markup. You can also bring your own API keys and pay your provider directly. We show full usage breakdowns per model and per twist, and you can set budgets so there are never surprises. Plot never profits from your AI usage.",
  },
  {
    question: "How do I add more connections on a Team plan?",
    answer:
      "Connections are added in groups of 50. You can add more at any time from your account settings. On annual plans, additional groups are prorated for the remainder of your billing cycle. The price updates dynamically so you can see the cost before confirming.",
  },
  {
    question: "Do annual plans auto-renew?",
    answer:
      "Yes. Annual plans renew automatically. You can cancel anytime before renewal, and you'll keep access through the end of your billing period.",
  },
  {
    question: "Is there an enterprise plan?",
    answer:
      "Not yet, but it's on our roadmap. If you need SSO, advanced security controls, or custom terms, reach out and we'll work with you.",
  },
];

export function meta(_: Route.MetaArgs) {
  return mergeMeta([
    { title: "Pricing | Plot" },
    {
      name: "description",
      content:
        "Simple pricing with no per-seat fees. Bring your whole team in without thinking twice.",
    },
    { property: "og:title", content: "Plot Pricing" },
    { property: "og:description", content: "Simple pricing. No per-seat fees. Bring your whole team in without thinking twice." },
    { name: "twitter:title", content: "Plot Pricing" },
    { name: "twitter:description", content: "Simple pricing. No per-seat fees. Bring your whole team in without thinking twice." },
  ]);
}

export default function Pricing() {
  const [billing, setBilling] = useState<Billing>("annual");

  return (
    <Stack gap={0}>
      {/* Hero */}
      <Box className={classes.heroSection} pt={60} pb={40}>
        <Container size="lg">
          <Stack align="center" gap="lg" ta="center">
            <Title order={1} className={classes.heroTitle}>
              <Text span inherit variant="gradient">
                Simple pricing.
                <br />
                No per-seat fees.
              </Text>
            </Title>
            <Text className={classes.heroSubtext}>
              Everyone collaborates in Plot for free.
              <br />
              You only pay for the connections that bring your conversations
              together.
            </Text>
          </Stack>
        </Container>
      </Box>

      {/* Billing Toggle */}
      <Box className={classes.heroSection} pb={40}>
        <Container size="lg">
          <Stack align="center" gap="xs">
            <Box
              style={{ display: "inline-grid", gridTemplateColumns: "1fr 1fr" }}
            >
              <Box />
              <Box
                style={{
                  display: "flex",
                  justifyContent: "center",
                  marginBottom: 6,
                }}
              >
                <Badge variant="filled" color="green" size="sm">
                  Save 20%
                </Badge>
              </Box>
              <SegmentedControl
                value={billing}
                onChange={(v) => setBilling(v as Billing)}
                data={[
                  { label: "Monthly", value: "monthly" },
                  { label: "Annual", value: "annual" },
                ]}
                size="md"
                style={{ gridColumn: "1 / -1" }}
              />
            </Box>
          </Stack>
        </Container>
      </Box>

      {/* Pricing Cards */}
      <Box className={classes.graySection} pt={40} pb={80}>
        <Container size="lg">
          <Box className={classes.pricingGrid}>
            {PLANS.map((plan) => (
              <div
                key={plan.key}
                className={
                  plan.highlight
                    ? classes.pricingCardHighlight
                    : classes.pricingCard
                }
              >
                {plan.badge && (
                  <Box className={classes.popularBadge}>{plan.badge}</Box>
                )}
                <Text className={classes.planName}>{plan.name}</Text>
                <Text className={classes.bestFor}>{plan.bestFor}</Text>
                <Text className={classes.planDescription}>
                  {plan.description}
                </Text>
                <Stack gap="xs" className={classes.featureList}>
                  {plan.features.map((feature) => (
                    <Box key={feature} className={classes.featureItem}>
                      <IconCheck
                        size={16}
                        color="var(--mantine-color-brand-6)"
                        className={classes.featureIcon}
                      />
                      <span>{feature}</span>
                    </Box>
                  ))}
                </Stack>
                <Box>
                  <Box className={classes.priceBox}>
                    <Text className={classes.price}>
                      {typeof plan.price === "function"
                        ? plan.price(billing)
                        : plan.price}
                    </Text>
                    {plan.period && (
                      <Text className={classes.pricePeriod}>{plan.period}</Text>
                    )}
                  </Box>
                  {plan.unit && (
                    <Text className={classes.priceUnit}>{plan.unit}</Text>
                  )}
                </Box>
                <Box className={classes.noteSlot}>
                  {plan.priceNote && (
                    <Text className={classes.annualNote}>{plan.priceNote}</Text>
                  )}
                  {billing === "annual" && plan.key !== "free" && (
                    <Text className={classes.annualNote}>Billed annually</Text>
                  )}
                </Box>
                <Button
                  variant={plan.ctaVariant}
                  fullWidth
                  component={Link}
                  to={plan.ctaLink(billing)}
                >
                  {plan.cta}
                </Button>
              </div>
            ))}
          </Box>
        </Container>
      </Box>

      {/* What's a connection? */}
      <Box className={classes.whiteSection} pt={60} pb={60}>
        <Container size="md">
          <Stack gap="lg">
            <Title order={2} size="h3" className={classes.sectionTitle}>
              What's a connection?
            </Title>
            <Text className={classes.sectionBody}>
              A connection is a link between Plot and one account in an external
              service. Each connected user in a service counts as one
              connection, and each connection gives you access to everything in
              that account (e.g. all your calendars from one Google account, all
              your projects in Linear, all your channels in a Slack workspace).
            </Text>
            <Box className={classes.connectionDiagram}>
              <Box className={classes.connectionItem}>
                <Text fw={600}>Gmail</Text>
                <Text className={classes.connectionDots} />
                <Text c="dimmed">80 connections</Text>
              </Box>
              <Box className={classes.connectionItem}>
                <Text fw={600}>Google Calendar</Text>
                <Text className={classes.connectionDots} />
                <Text c="dimmed">80 connections</Text>
              </Box>
              <Box className={classes.connectionItem}>
                <Text fw={600}>Slack</Text>
                <Text className={classes.connectionDots} />
                <Text c="dimmed">80 connections</Text>
              </Box>
              <Box className={classes.connectionItem}>
                <Text fw={600}>Notion</Text>
                <Text className={classes.connectionDots} />
                <Text c="dimmed">80 connections</Text>
              </Box>
              <Box className={classes.connectionItem}>
                <Text fw={600}>Linear</Text>
                <Text className={classes.connectionDots} />
                <Text c="dimmed">35 connections</Text>
              </Box>
              <Box className={classes.connectionItem}>
                <Text fw={600}>GitHub</Text>
                <Text className={classes.connectionDots} />
                <Text c="dimmed">35 connections</Text>
              </Box>
              <Box className={classes.connectionItem}>
                <Text fw={600}>Figma</Text>
                <Text className={classes.connectionDots} />
                <Text c="dimmed">12 connections</Text>
              </Box>
              <Box className={classes.connectionItem}>
                <Text fw={600}>HubSpot</Text>
                <Text className={classes.connectionDots} />
                <Text c="dimmed">15 connections</Text>
              </Box>
              <Box className={classes.connectionItem}>
                <Text fw={600}>Intercom</Text>
                <Text className={classes.connectionDots} />
                <Text c="dimmed">8 connections</Text>
              </Box>
              <Box className={classes.connectionItem}>
                <Text fw={600}>Loom</Text>
                <Text className={classes.connectionDots} />
                <Text c="dimmed">35 connections</Text>
              </Box>
              <Box className={classes.connectionItem}>
                <Text fw={600}>PostHog</Text>
                <Text className={classes.connectionDots} />
                <Text c="dimmed">26 connections</Text>
              </Box>
              <Box className={classes.connectionTotal}>
                <Text fw={700}>Total: 486 connections</Text>
              </Box>
            </Box>
            <Text className={classes.sectionBody}>
              An 80-person team uses around 500 connections — everyone connects
              their core tools, plus specialized ones for each team.
            </Text>
          </Stack>
        </Container>
      </Box>

      {/* What's a twist? */}
      <Box className={classes.graySection} pt={60} pb={60}>
        <Container size="md">
          <Stack gap="lg">
            <Title order={2} size="h3" className={classes.sectionTitle}>
              What's a twist?
            </Title>
            <Text className={classes.sectionBody}>
              Twists are extensions that add new capabilities to Plot —
              automations, agents, and custom workflows that make Plot work the
              way your business works. Install twists published by others, or
              build your own.
            </Text>
            <Text className={classes.sectionBody} fw={700}>
              All twists are hosted and run securely within Plot.
            </Text>
            <Text className={classes.sectionBody}>
              Some twists use AI to do their work. When they do, AI usage is
              billed at cost — no markup, no margin. You can also bring your own
              API keys and pay your provider directly. Set budgets to stay in
              control.
            </Text>
            <Text className={classes.sectionBody}>
              Plot never profits from your AI usage, so we'll never push you to
              use more.
            </Text>
          </Stack>
        </Container>
      </Box>

      {/* FAQ Section */}
      <Box className={classes.faqSection} pt={60} pb={80}>
        <Container size="md">
          <Stack gap="xl">
            <Title
              order={2}
              size="h2"
              className={classes.sectionTitle}
              ta="center"
            >
              Frequently asked questions
            </Title>
            <Accordion variant="separated">
              {FAQS.map((faq) => (
                <Accordion.Item key={faq.question} value={faq.question}>
                  <Accordion.Control className={classes.faqQuestion}>
                    {faq.question}
                  </Accordion.Control>
                  <Accordion.Panel>
                    <Text className={classes.faqAnswer}>{faq.answer}</Text>
                  </Accordion.Panel>
                </Accordion.Item>
              ))}
            </Accordion>
          </Stack>
        </Container>
      </Box>

      {/* Final CTA */}
      <Box className={classes.ctaSection} pt={80} pb={80}>
        <Container size="sm">
          <Stack gap="lg" align="center" ta="center">
            <Button variant="white" size="xl" component={Link} to="/start">
              Get started for free
            </Button>
          </Stack>
        </Container>
      </Box>
    </Stack>
  );
}
