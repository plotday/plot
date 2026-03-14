import { useState, useEffect } from "react";

import { useAuth } from "@clerk/react-router";
import { Link, useSearchParams } from "react-router";

import {
  Alert,
  Box,
  Button,
  Checkbox,
  Container,
  Loader,
  SegmentedControl,
  Select,
  Stack,
  Text,
  TextInput,
  Title,
  Badge,
} from "@mantine/core";

import { IconCheck } from "@tabler/icons-react";

import type { Route } from "./+types/subscribe";
import classes from "./subscribe.module.css";

type Billing = "monthly" | "annual";

type SubscriptionInfo = {
  plan: string;
  status: string;
  billing_cycle_end: string | null;
  effective_plan?: string;
  effective_source?: string;
  organization?: { id: string; name: string } | null;
};

const PRICES = {
  pro: { monthly: 25, annual: 20 },
  business: { monthly: 124, annual: 99 },
} as const;

const QUANTITY_OPTIONS = Array.from({ length: 40 }, (_, i) => ({
  value: String(i + 1),
  label: `${(i + 1) * 50} connections`,
}));

export function meta(_: Route.MetaArgs) {
  return [
    { title: "Subscribe | Plot" },
    {
      name: "description",
      content: "Manage your Plot subscription.",
    },
  ];
}

export async function loader({ context }: Route.LoaderArgs) {
  return {
    apiUrl: context.cloudflare.env.API_ROOT || "https://api.plot.day",
  };
}

export default function Subscribe({ loaderData }: Route.ComponentProps) {
  const { isSignedIn, isLoaded, getToken } = useAuth();
  const [searchParams] = useSearchParams();
  const [subscription, setSubscription] = useState<SubscriptionInfo | null>(
    null
  );
  const [loading, setLoading] = useState(true);
  const [actionLoading, setActionLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [billing, setBilling] = useState<Billing>(
    (searchParams.get("billing") as Billing) || "annual"
  );
  const [businessQuantity, setBusinessQuantity] = useState("1");
  const [orgName, setOrgName] = useState("");
  const [domainAutoJoin, setDomainAutoJoin] = useState(true);

  const isSuccess = searchParams.get("success") === "true";
  const isCanceled = searchParams.get("canceled") === "true";
  const successOrgId = searchParams.get("org");

  // Fetch subscription status
  useEffect(() => {
    if (!isSignedIn) {
      setLoading(false);
      return;
    }

    async function fetchSubscription() {
      try {
        const token = await getToken();
        const res = await fetch(`${loaderData.apiUrl}/app/subscribe`, {
          headers: { Authorization: `Bearer ${token}` },
        });
        if (res.ok) {
          setSubscription(await res.json());
        }
      } catch {
        // Ignore fetch errors, show free plan
      } finally {
        setLoading(false);
      }
    }
    fetchSubscription();
  }, [isSignedIn, getToken, loaderData.apiUrl]);

  const handleCheckout = async (plan: "pro" | "business") => {
    setActionLoading(true);
    setError(null);

    try {
      const token = await getToken();
      const lookupKey = `${plan}_${billing}`;
      const body: Record<string, unknown> = {
        priceLookupKey: lookupKey,
      };
      if (plan === "business") {
        body.quantity = parseInt(businessQuantity);
        if (!subscription?.organization) {
          // Creating a new org
          if (!orgName.trim()) {
            setError("Organization name is required for Business plan");
            setActionLoading(false);
            return;
          }
          body.organizationName = orgName.trim();
          body.domainAutoJoin = domainAutoJoin;
        } else {
          body.organizationId = subscription.organization.id;
        }
      }

      const res = await fetch(
        `${loaderData.apiUrl}/app/subscribe/checkout`,
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${token}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify(body),
        }
      );

      if (!res.ok) {
        const data = (await res.json()) as { error?: string };
        throw new Error(data.error || "Failed to create checkout session");
      }

      const { url } = (await res.json()) as { url: string };
      window.location.href = url;
    } catch (err) {
      setError(
        err instanceof Error ? err.message : "Something went wrong"
      );
      setActionLoading(false);
    }
  };

  const handlePortal = async (orgId?: string) => {
    setActionLoading(true);
    setError(null);

    try {
      const token = await getToken();
      const portalUrl = orgId
        ? `${loaderData.apiUrl}/app/organization/${orgId}/subscribe/portal`
        : `${loaderData.apiUrl}/app/subscribe/portal`;

      const res = await fetch(portalUrl, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
      });

      if (!res.ok) {
        const data = (await res.json()) as { error?: string };
        throw new Error(data.error || "Failed to open billing portal");
      }

      const { url } = (await res.json()) as { url: string };
      window.location.href = url;
    } catch (err) {
      setError(
        err instanceof Error ? err.message : "Something went wrong"
      );
      setActionLoading(false);
    }
  };

  if (!isLoaded) return null;

  // Not signed in
  if (!isSignedIn) {
    return (
      <Container size="sm" mt="xl" mb="xl">
        <Stack gap="md" align="center" ta="center">
          <Title order={2}>Manage your subscription</Title>
          <Text c="dimmed">Sign in to view or manage your subscription.</Text>
          <Button
            component={Link}
            to={`/signin?returnTo=/subscribe${searchParams.get("plan") ? `?plan=${searchParams.get("plan")}&billing=${billing}` : ""}`}
          >
            Sign in to continue
          </Button>
        </Stack>
      </Container>
    );
  }

  // Loading
  if (loading) {
    return (
      <Container size="sm" mt="xl" mb="xl">
        <Stack align="center" gap="md">
          <Loader />
          <Text c="dimmed">Loading subscription...</Text>
        </Stack>
      </Container>
    );
  }

  // Success / Canceled alerts
  const alerts = (
    <>
      {isSuccess && (
        <Alert color="green" title="Subscription active" mb="md">
          Your subscription is now active.
          {successOrgId
            ? " Your organization has been set up."
            : ` Welcome to Plot ${subscription?.effective_plan === "business" ? "Business" : "Pro"}!`}
        </Alert>
      )}
      {isCanceled && (
        <Alert color="yellow" title="Checkout canceled" mb="md">
          Your checkout was canceled. No charges were made.
        </Alert>
      )}
      {error && (
        <Alert color="red" title="Error" mb="md">
          {error}
        </Alert>
      )}
    </>
  );

  const effectivePlan = subscription?.effective_plan ?? subscription?.plan ?? "free";
  const isOrgPlan = subscription?.effective_source === "organization";

  // Has paid plan (either personal or via org)
  const hasPaidPlan = effectivePlan !== "free" && subscription?.status === "active";

  if (hasPaidPlan) {
    return (
      <Container size="sm" mt="xl" mb="xl">
        <Stack gap="md">
          <Title order={2}>Your subscription</Title>
          {alerts}
          <Box className={classes.currentPlan}>
            <Text fw={600} size="lg">
              Plot {effectivePlan === "business" ? "Business" : "Pro"}
              {isOrgPlan && subscription?.organization
                ? ` via ${subscription.organization.name}`
                : ""}
            </Text>
            <Badge color="green" variant="light">
              Active
            </Badge>
          </Box>
          {subscription?.billing_cycle_end && !isOrgPlan && (
            <Text c="dimmed" size="sm">
              Current billing period ends{" "}
              {new Date(subscription.billing_cycle_end).toLocaleDateString()}
            </Text>
          )}
          {isOrgPlan && subscription?.organization && (
            <Button
              component={Link}
              to={`/organization/${subscription.organization.id}`}
              variant="outline"
            >
              Manage organization
            </Button>
          )}
          {!isOrgPlan && (
            <Button
              onClick={() => handlePortal()}
              loading={actionLoading}
              variant="outline"
            >
              Manage subscription
            </Button>
          )}
        </Stack>
      </Container>
    );
  }

  // No paid plan — show plan selection
  const preselectedPlan = searchParams.get("plan");

  return (
    <Container size="lg" mt="xl" mb="xl">
      <Stack gap="lg">
        <Stack align="center" ta="center" gap="xs">
          <Title order={2}>Choose your plan</Title>
          <Text c="dimmed">
            Upgrade for unlimited connections and premium features.
          </Text>
        </Stack>

        {alerts}

        <Stack align="center">
          <Box className={classes.toggleWrapper}>
            <SegmentedControl
              value={billing}
              onChange={(v) => setBilling(v as Billing)}
              data={[
                { label: "Monthly", value: "monthly" },
                { label: "Annual", value: "annual" },
              ]}
              size="md"
            />
            {billing === "annual" && (
              <Badge variant="light" color="green" size="sm">
                Save 20%
              </Badge>
            )}
          </Box>
        </Stack>

        <Box className={classes.planGrid}>
          {/* Pro */}
          <Stack
            className={
              preselectedPlan === "pro"
                ? classes.planCardHighlight
                : classes.planCard
            }
            gap="md"
          >
            <Text className={classes.planName}>Pro</Text>
            <Text className={classes.bestFor}>
              For individuals working across many tools
            </Text>
            <Stack gap="xs" className={classes.featureList}>
              {[
                "Unlimited connections",
                "Unlimited twists (AI usage may apply)",
                "All core features for team collaboration",
                "Unlimited collaborators",
                "Full history of all your work",
                "Automated organization and prioritization",
              ].map((f) => (
                <Box key={f} className={classes.featureItem}>
                  <IconCheck
                    size={16}
                    color="var(--mantine-color-brand-6)"
                  />
                  <span>{f}</span>
                </Box>
              ))}
            </Stack>
            <Box className={classes.priceDivider} />
            <Box className={classes.priceBox}>
              <Text className={classes.planPrice}>
                ${PRICES.pro[billing]}
              </Text>
              <Text className={classes.planPricePeriod}>/mo</Text>
            </Box>
            {billing === "annual" && (
              <Text c="dimmed" size="xs" mt={-8}>
                Billed annually
              </Text>
            )}
            <Button
              onClick={() => handleCheckout("pro")}
              loading={actionLoading}
              fullWidth
            >
              Subscribe to Pro
            </Button>
          </Stack>

          {/* Business */}
          <Stack
            className={
              preselectedPlan === "business"
                ? classes.planCardHighlight
                : classes.planCard
            }
            gap="md"
          >
            <Text className={classes.planName}>Business</Text>
            <Text className={classes.bestFor}>
              For ambitious teams who move fast together
            </Text>
            <Stack gap="xs" className={classes.featureList}>
              {[
                "50+ connections shared across your org",
                "Unlimited twists (AI usage may apply)",
                "All core features for team collaboration",
                "Unlimited team members",
                "Full history of all your work",
                "Automated organization and prioritization",
                "Organization-level controls",
              ].map((f) => (
                <Box key={f} className={classes.featureItem}>
                  <IconCheck
                    size={16}
                    color="var(--mantine-color-brand-6)"
                  />
                  <span>{f}</span>
                </Box>
              ))}
            </Stack>
            <Box className={classes.priceDivider} />
            <Select
              value={businessQuantity}
              onChange={(v) => v && setBusinessQuantity(v)}
              data={QUANTITY_OPTIONS}
              size="sm"
            />
            <TextInput
              label="Organization name"
              placeholder="Your company name"
              value={orgName}
              onChange={(e) => setOrgName(e.currentTarget.value)}
              size="sm"
            />
            <Checkbox
              label="Allow anyone with the same email domain to join"
              checked={domainAutoJoin}
              onChange={(e) => setDomainAutoJoin(e.currentTarget.checked)}
              size="sm"
            />
            <Box className={classes.priceDivider} />
            <Box className={classes.priceBox}>
              <Text className={classes.planPrice}>
                ${PRICES.business[billing] * parseInt(businessQuantity)}
              </Text>
              <Text className={classes.planPricePeriod}>/mo</Text>
            </Box>
            {billing === "annual" && (
              <Text c="dimmed" size="xs" mt={-8}>
                Billed annually
              </Text>
            )}
            <Button
              onClick={() => handleCheckout("business")}
              loading={actionLoading}
              fullWidth
            >
              Subscribe to Business
            </Button>
          </Stack>
        </Box>
      </Stack>
    </Container>
  );
}
