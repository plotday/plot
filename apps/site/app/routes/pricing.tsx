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
import { mergeMeta } from "~/lib/meta";
import { ADDON_PRICE, PLANS } from "~/lib/plans";
import type { Billing } from "~/lib/plans";

import type { Route } from "./+types/pricing";
import classes from "./pricing.module.css";

const FAQS = [
  {
    question: "How does Plot's pricing work?",
    answer:
      "The whole platform is free to use, forever. You pay only for the things you add on top: extra connections (the accounts you link) and automations. Most people start free and add connections as they grow.",
  },
  {
    question: "What counts as a connection?",
    answer:
      "One account you link to Plot — one Google account, one Slack workspace, one Linear org. Each account is one connection and brings in everything inside it. Linking your personal and work Google accounts is two connections. Composite connectors count once: one Google connection covers Gmail, Calendar, and Tasks; one Outlook connection covers mail and calendar.",
  },
  {
    question: "What's a connection add-on?",
    answer:
      "Every plan includes some connections; each connection beyond that is a $5/month add-on. On Free you start with 2 and can add more at $5/month each — and once you'd need about five extra, Pro (with unlimited connections) is the better deal. A few connectors always require an add-on, even on a paid plan — see the next question.",
  },
  {
    question: "Which connectors always need an add-on?",
    answer:
      "LinkedIn, Instagram, and WhatsApp. They're provided through a third party with real per-account costs, so they always need a $5/month connection add-on — on any plan, including Free — and they don't count toward your included connections.",
  },
  {
    question: "What happens when I reach my connection limit?",
    answer:
      "On Free, add connections for $5/month each, or upgrade to Pro for unlimited. On Team, add another block of 50 connections or twist automations anytime; on annual billing, added blocks are prorated for the rest of your cycle.",
  },
  {
    question: "What's an automation?",
    answer:
      "An automation (we call them twists) extends Plot with an agent or a custom workflow that acts on your behalf. Install ones made by others, or build your own with the no-code builder. They all run securely inside Plot.",
  },
  {
    question: "How does automation capacity work?",
    answer:
      "Your plan includes a number of twist automation slots — 1 on Free, 3 on Pro. Most twist automations use one slot; heavier ones use more (a 2× twist automation uses two). It's based on what you have turned on, so you can free up room by turning one off — or add 5 twist automations for $10/month.",
  },
  {
    question: "How does AI work, and what does it cost?",
    answer:
      "AI is built in. The Plot assistant is included on every plan, and when an automation uses AI the cost is already included in its capacity — no token bills, no API keys, nothing to configure.",
  },
  {
    question: "Is collaboration really free?",
    answer:
      "Yes, some teams use Plot to completely replace other platforms like Slack or Teams. Plot users share threads with no limits on sharing or history.",
  },
  {
    question: "How far back does Plot import from my connected services?",
    answer:
      "Plot imports recent items when you connect: 1 week on Free, 1 year on Pro and Team. After that, everything syncs in real time, and everything already in Plot stays forever — the limit only applies to the initial import.",
  },
  {
    question: "Do annual plans auto-renew?",
    answer:
      "Yes. Annual plans renew automatically. You can cancel anytime before renewal, and you'll keep access through the end of your billing period.",
  },
  {
    question: "Is there an enterprise plan?",
    answer:
      "Not yet. If you need SSO, advanced security controls, or custom terms, reach out and we'll work with you.",
  },
];

export function meta(_: Route.MetaArgs) {
  const description =
    "Plot is free to use, forever. Pay only to extend with extra connections and automations.";
  return mergeMeta([
    { title: "Pricing | Plot" },
    { name: "description", content: description },
    { property: "og:title", content: "Plot Pricing" },
    { property: "og:description", content: description },
    { name: "twitter:title", content: "Plot Pricing" },
    { name: "twitter:description", content: description },
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
                Everything you need to
                <br />
                bring your work together.
              </Text>
            </Title>
            <Text className={classes.heroSubtext}>
              Plot is free to use, forever.
              <br />
              Pay only to extend with extra connections and automations.
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
          <Text className={classes.addonFootnote}>
            A few connectors — LinkedIn, Instagram, and WhatsApp — always need a
            ${ADDON_PRICE}/mo connection add-on, on any plan. They don't count
            toward your included connections.
          </Text>
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
              A connection is one account you link to Plot — one Google account,
              one Slack workspace, one Linear org. Each account is one
              connection, and one connection brings in everything inside it.
            </Text>
            <Text className={classes.sectionBody}>
              Connections are per account, not per app. If you link your
              personal Google and your work Google, that's two connections. And
              because Plot groups an account's tools together, one Google
              connection covers Gmail, Calendar, and Tasks; one Outlook
              connection covers mail and calendar.
            </Text>
            <Text className={classes.sectionBody}>
              Each plan includes a set number of connections, and you can add
              more for ${ADDON_PRICE}/mo each. A few connectors always need an
              add-on — see the FAQ below for the details.
            </Text>
            <Text className={classes.sectionBody}>
              For a team, connections add up across everyone's tools — here's
              how an 80-person team might look:
            </Text>
            <Box className={classes.connectionDiagram}>
              <Box className={classes.connectionItem}>
                <Text fw={600}>Google</Text>
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
                <Text fw={600}>HubSpot</Text>
                <Text className={classes.connectionDots} />
                <Text c="dimmed">15 connections</Text>
              </Box>
              <Box className={classes.connectionItem}>
                <Text fw={600}>Loom</Text>
                <Text className={classes.connectionDots} />
                <Text c="dimmed">15 connections</Text>
              </Box>
              <Box className={classes.connectionItem}>
                <Text fw={600}>Intercom</Text>
                <Text className={classes.connectionDots} />
                <Text c="dimmed">12 connections</Text>
              </Box>
              <Box className={classes.connectionItem}>
                <Text fw={600}>Linear</Text>
                <Text className={classes.connectionDots} />
                <Text c="dimmed">35 connections</Text>
              </Box>
              <Box className={classes.connectionItem}>
                <Text fw={600}>Figma</Text>
                <Text className={classes.connectionDots} />
                <Text c="dimmed">12 connections</Text>
              </Box>
              <Box className={classes.connectionItem}>
                <Text fw={600}>GitHub</Text>
                <Text className={classes.connectionDots} />
                <Text c="dimmed">26 connections</Text>
              </Box>
              <Box className={classes.connectionItem}>
                <Text fw={600}>PostHog</Text>
                <Text className={classes.connectionDots} />
                <Text c="dimmed">26 connections</Text>
              </Box>
              <Box className={classes.connectionTotal}>
                <Text fw={700}>Total: 381 connections</Text>
              </Box>
            </Box>
            <Text className={classes.sectionBody}>
              An 80-person team uses just under 400 connections — everyone
              connects their core tools, plus specialized ones for each team.
            </Text>
          </Stack>
        </Container>
      </Box>

      {/* What's an automation? */}
      <Box className={classes.graySection} pt={60} pb={60}>
        <Container size="md">
          <Stack gap="lg">
            <Title order={2} size="h3" className={classes.sectionTitle}>
              What's an automation?
            </Title>
            <Text className={classes.sectionBody}>
              Automations — we call them twists — add new capabilities to Plot:
              agents and custom workflows that act on your behalf. Install ones
              published by others, or build your own with the no-code builder.
            </Text>
            <Text className={classes.sectionBody} fw={700}>
              All automations are hosted and run securely within Plot.
            </Text>
            <Text className={classes.sectionBody}>
              Your plan includes twist automation capacity — Free includes 1,
              Pro includes 3. A heavier twist automation uses more: a 2× twist
              automation takes 2 of your capacity. Turn one off to free up room,
              or add 5 more twist automations for $10/mo.
            </Text>
            <Text className={classes.sectionBody}>
              When an automation uses AI, that cost is already included in its
              capacity — there's no separate AI bill, no API keys to bring, and
              nothing to configure.
            </Text>
            <Text className={classes.sectionBody}>
              The built-in Plot assistant is included on every plan and never
              uses your automation capacity — it's the general-purpose helper,
              included on Free too.
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
