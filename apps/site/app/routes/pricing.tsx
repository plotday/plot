import { Box, Button, Container, Stack, Text, Title } from "@mantine/core";

import { IconCheck } from "@tabler/icons-react";

import type { Route } from "./+types/pricing";
import classes from "./pricing.module.css";

const PLANS = [
  {
    name: "Free Forever",
    price: "$0",
    period: "",
    description: "Unlimited collaboration for any team",
    features: [
      "Unlimited people",
      "Unlimited conversations",
      "Unlimited priorities",
    ],
    cta: "Get started",
    ctaVariant: "outline" as const,
    highlight: false,
  },
  {
    name: "Pro",
    price: "$12",
    period: "/month",
    description: "For individual productivity",
    features: [
      "Everything in Free",
      "Access to all twists",
      "Individual twist use only",
    ],
    cta: "Start free trial",
    ctaVariant: "filled" as const,
    highlight: false,
  },
  {
    name: "Team",
    price: "$79",
    period: "/month",
    description: "For core teams of up 10 people",
    features: [
      "Everything in Pro",
      "Up to 10 twist users",
      "Shared twists allowing 2-way sync with team apps like Notion, Figma, and Linear",
    ],
    cta: "Start free trial",
    ctaVariant: "gradient" as const,
    highlight: true,
  },
  {
    name: "Business",
    price: "$199",
    period: "/month",
    description: "For organizations of up to 30 people",
    features: [
      "Everything in Team",
      "Up to 30 twist users",
      "Priority support",
    ],
    cta: "Start free trial",
    ctaVariant: "filled" as const,
    highlight: false,
  },
  {
    name: "Enterprise",
    price: "Custom",
    period: "",
    description: "For large organizations",
    features: [
      "Everything in Business",
      "Cover all your organization's people and use cases",
      "Dedicated support",
      "Custom integrations",
    ],
    cta: "Contact us",
    ctaVariant: "outline" as const,
    highlight: false,
  },
];

const FAQS = [
  {
    question: "What is a twist?",
    answer:
      "Twists are integrations and automations that bring your work from other apps into Plot. They can sync your calendar, emails, project management tools, and more—automatically organized and prioritized.",
  },
  {
    question: "What does 'twist users' mean?",
    answer:
      "Twist users are people in your workspace who can use twist features. Everyone can collaborate in Plot for free, but only twist users get access to synced data from integrations.",
  },
  {
    question: "How does the free trial work?",
    answer:
      "All paid plans include a 30-day free trial. You can try any plan with full features, no credit card required. Downgrade to Free at any time if you don't need twists.",
  },
  {
    question: "What is pay-what-you-want pricing?",
    answer:
      "During our early access period, we're offering pay-what-you-want pricing. Use the suggested prices as a guide, but pay based on the value you receive. This helps us learn what Plot is worth to different teams.",
  },
  {
    question: "Can I switch plans later?",
    answer:
      "Yes, you can upgrade or downgrade your plan at any time. If you upgrade, you'll be credited for the remaining time on your current plan. If you downgrade, the change takes effect at the end of your billing period.",
  },
];

export function meta(_: Route.MetaArgs) {
  return [
    { title: "Pricing | Plot" },
    {
      name: "description",
      content:
        "Simple, transparent pricing. Free unlimited collaboration. Paid plans for twists and integrations.",
    },
    { "og:title": "Plot Pricing" },
    {
      "og:description":
        "Simple, transparent pricing for prioritized team collaboration.",
    },
    { "og:image": "https://plot.day/assets/p.png" },
    { "twitter:title": "Plot Pricing" },
    {
      "twitter:description":
        "Simple, transparent pricing for prioritized team collaboration.",
    },
    { "twitter:image": "https://plot.day/assets/p.png" },
  ];
}

export default function Pricing() {
  return (
    <Stack gap={0}>
      {/* Hero */}
      <Box className={classes.heroSection} pt={60} pb={60}>
        <Container size="lg">
          <Stack align="center" gap="lg" ta="center">
            <Title order={1} className={classes.heroTitle}>
              <Text span inherit variant="gradient">
                Free to collaborate, value-based pricing
              </Text>
            </Title>
            <Text className={classes.heroSubtext}>
              Unlimited collaboration is free forever. Add twists to supercharge
              your productivity with integrations and automations.
            </Text>
          </Stack>
        </Container>
      </Box>

      {/* Pricing Cards */}
      <Box className={classes.graySection} pt={40} pb={80}>
        <Container size="xl">
          <Box className={classes.pricingGrid}>
            {PLANS.map((plan) => (
              <Stack
                key={plan.name}
                className={
                  plan.highlight
                    ? classes.pricingCardHighlight
                    : classes.pricingCard
                }
                gap="md"
              >
                {plan.highlight && false && (
                  <Box className={classes.popularBadge}>Most Popular</Box>
                )}
                <Text className={classes.planName}>{plan.name}</Text>
                <Box className={classes.priceBox}>
                  <Text className={classes.price}>{plan.price}</Text>
                  {plan.period && (
                    <Text className={classes.pricePeriod}>{plan.period}</Text>
                  )}
                </Box>
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
                <Button
                  variant={plan.ctaVariant}
                  fullWidth
                  component="a"
                  href="https://app.plot.day"
                >
                  {plan.cta}
                </Button>
              </Stack>
            ))}
          </Box>
        </Container>
      </Box>

      {/* Pay What You Want Banner */}
      <Box className={classes.whiteSection} pt={60} pb={60}>
        <Container size="md">
          <Stack
            className={classes.payWhatYouWantBanner}
            gap="md"
            align="center"
            ta="center"
          >
            <Title order={3} className={classes.bannerTitle}>
              Early Access: Pay For Value
            </Title>
            <Text className={classes.bannerText}>
              While we grow the breadth and depth of twists, you can set your
              price for all paid plans based on the value you receive. We're
              confident we'll earn and grow your busienss. All paid plans
              include a 30-day free trial with no credit card required.
            </Text>
            <Button
              variant="gradient"
              size="lg"
              component="a"
              href="https://app.plot.day"
            >
              Start your free trial
            </Button>
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
            <Stack gap={0}>
              {FAQS.map((faq) => (
                <Box key={faq.question} className={classes.faqItem}>
                  <Text className={classes.faqQuestion}>{faq.question}</Text>
                  <Text className={classes.faqAnswer}>{faq.answer}</Text>
                </Box>
              ))}
            </Stack>
          </Stack>
        </Container>
      </Box>

      {/* Final CTA */}
      <Box className={classes.ctaSection} pt={80} pb={80}>
        <Container size="sm">
          <Stack gap="lg" align="center" ta="center">
            <Title order={2} size="h2" className={classes.ctaTitle}>
              Ready to prioritize progress?
            </Title>
            <Text c="rgba(255,255,255,0.85)" fz="lg">
              Start free with unlimited collaboration, or try twists with a
              30-day free trial.
            </Text>
            <Button
              variant="white"
              size="xl"
              component="a"
              href="https://app.plot.day"
            >
              Get started free
            </Button>
          </Stack>
        </Container>
      </Box>
    </Stack>
  );
}
