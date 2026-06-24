import { useEffect, useState } from "react";

import {
  Alert,
  Badge,
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
} from "@mantine/core";

import { SignIn, useAuth, useClerk, useUser } from "@clerk/react-router";
import { IconCheck } from "@tabler/icons-react";
import { Link, useSearchParams } from "react-router";
import { ADDON_PRICE, PLANS, PRICES } from "~/lib/plans";
import type { Billing } from "~/lib/plans";

import type { Route } from "./+types/upgrade";
import classes from "./upgrade.module.css";

const FREEMAIL_DOMAINS = new Set([
  "gmail.com",
  "yahoo.com",
  "hotmail.com",
  "outlook.com",
  "icloud.com",
  "aol.com",
  "protonmail.com",
  "proton.me",
  "mail.com",
  "zoho.com",
  "yandex.com",
  "gmx.com",
  "live.com",
  "me.com",
  "msn.com",
]);

type OrgInfo = {
  id: string;
  name: string;
  role: string;
  plan: string;
  status: string;
  memberCount: number;
};

type SubscriptionInfo = {
  plan: string;
  status: string;
  billing_cycle_end: string | null;
  effective_plan?: string;
  effective_source?: string;
  teams: OrgInfo[];
};

const QUANTITY_OPTIONS = Array.from({ length: 40 }, (_, i) => ({
  value: String((i + 1) * 50),
  label: `${(i + 1) * 50} connections`,
}));

export function meta(_: Route.MetaArgs) {
  return [
    { title: "Upgrade | Plot" },
    {
      name: "description",
      content: "Manage your Plot plan.",
    },
  ];
}

export async function loader({ context }: Route.LoaderArgs) {
  return {
    apiUrl: context.cloudflare.env.API_ROOT || "https://api.plot.day",
  };
}

export default function Upgrade({ loaderData }: Route.ComponentProps) {
  const { isSignedIn, isLoaded, getToken } = useAuth();
  const { user } = useUser();
  const { signOut } = useClerk();
  const [searchParams] = useSearchParams();
  const expectedEmail = searchParams.get("email")?.toLowerCase() || null;
  const currentEmail =
    user?.primaryEmailAddress?.emailAddress?.toLowerCase() || null;
  const emailMismatch =
    isLoaded &&
    isSignedIn &&
    expectedEmail !== null &&
    currentEmail !== null &&
    expectedEmail !== currentEmail;

  // If the Clerk session is for a different user than the app opened this page
  // for (e.g. website signed in as a personal account, app signed in as work),
  // sign out so the user can sign in with the correct account. Pass redirectUrl
  // so Clerk doesn't navigate to "/" by default and drop us on the home page.
  useEffect(() => {
    if (emailMismatch) {
      signOut({
        redirectUrl: `${window.location.pathname}${window.location.search}`,
      });
    }
  }, [emailMismatch, signOut]);
  const [subscription, setSubscription] = useState<SubscriptionInfo | null>(
    null,
  );
  const [loading, setLoading] = useState(true);
  const [loadingPlan, setLoadingPlan] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [billing, setBilling] = useState<Billing>(
    (searchParams.get("billing") as Billing) || "annual",
  );
  const [teamQuantity, setTeamQuantity] = useState("50");
  const [orgName, setOrgName] = useState("");
  const [domainAutoJoin, setDomainAutoJoin] = useState(true);
  // Number of $5/mo connection add-ons on the personal plan (from /usage).
  const [addonCount, setAddonCount] = useState(0);
  const [addonBusy, setAddonBusy] = useState(false);

  const emailDomain = user?.primaryEmailAddress?.emailAddress
    ?.split("@")[1]
    ?.toLowerCase();
  const isFreemailDomain = !emailDomain || FREEMAIL_DOMAINS.has(emailDomain);

  // Reset loading state when page is restored from bfcache (browser back from Stripe)
  useEffect(() => {
    const handlePageShow = (e: PageTransitionEvent) => {
      if (e.persisted) setLoadingPlan(null);
    };
    window.addEventListener("pageshow", handlePageShow);
    return () => window.removeEventListener("pageshow", handlePageShow);
  }, []);

  const isSuccess = searchParams.get("success") === "true";
  const isCanceled = searchParams.get("canceled") === "true";
  const successOrgId = searchParams.get("org");

  // Fetch subscription status
  useEffect(() => {
    if (!isSignedIn || emailMismatch) {
      setLoading(false);
      return;
    }

    async function fetchSubscription() {
      try {
        const token = await getToken();
        const [subRes, usageRes] = await Promise.all([
          fetch(`${loaderData.apiUrl}/app/upgrade`, {
            headers: { Authorization: `Bearer ${token}` },
          }),
          fetch(`${loaderData.apiUrl}/app/upgrade/usage`, {
            headers: { Authorization: `Bearer ${token}` },
          }),
        ]);
        if (subRes.ok) {
          setSubscription(await subRes.json());
        }
        if (usageRes.ok) {
          const usage = (await usageRes.json()) as {
            personal?: { premium?: { purchased?: number } };
          };
          setAddonCount(usage.personal?.premium?.purchased ?? 0);
        }
      } catch {
        // Ignore fetch errors, show free plan
      } finally {
        setLoading(false);
      }
    }
    fetchSubscription();
  }, [isSignedIn, emailMismatch, getToken, loaderData.apiUrl]);

  const handleCheckout = async (plan: "core" | "pro" | "team") => {
    setLoadingPlan(plan);
    setError(null);

    try {
      const token = await getToken();
      const lookupKey = `${plan}_${billing}`;
      const body: Record<string, unknown> = {
        priceLookupKey: lookupKey,
      };
      if (plan === "team") {
        body.quantity = parseInt(teamQuantity);
        if (!orgName.trim()) {
          setError("Team name is required for Team plan");
          setLoadingPlan(null);
          return;
        }
        body.teamName = orgName.trim();
        body.domainAutoJoin = isFreemailDomain ? false : domainAutoJoin;
      }

      const res = await fetch(`${loaderData.apiUrl}/app/upgrade/checkout`, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(body),
      });

      if (!res.ok) {
        const data = (await res.json()) as { error?: string };
        throw new Error(data.error || "Failed to create checkout session");
      }

      const { url } = (await res.json()) as { url: string };
      window.location.href = url;
    } catch (err) {
      setError(err instanceof Error ? err.message : "Something went wrong");
      setLoadingPlan(null);
    }
  };

  // Set the personal plan's connection add-on count. Stripe prorates the
  // change on the existing subscription; no checkout redirect needed.
  const handleSetAddons = async (quantity: number) => {
    if (quantity < 0) return;
    setAddonBusy(true);
    setError(null);
    try {
      const token = await getToken();
      const res = await fetch(`${loaderData.apiUrl}/app/upgrade/addons`, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ quantity }),
      });
      if (!res.ok) {
        const data = (await res.json()) as { error?: string };
        throw new Error(
          data.error === "manage_in_app"
            ? "Manage add-ons in the Plot app on this device."
            : data.error || "Failed to update add-ons",
        );
      }
      const { addons } = (await res.json()) as { addons: number };
      setAddonCount(addons);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Something went wrong");
    } finally {
      setAddonBusy(false);
    }
  };

  const handlePortal = async (orgId?: string) => {
    setLoadingPlan("portal");
    setError(null);

    try {
      const token = await getToken();
      const portalUrl = orgId
        ? `${loaderData.apiUrl}/app/team/${orgId}/upgrade/portal`
        : `${loaderData.apiUrl}/app/upgrade/portal`;

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
      setError(err instanceof Error ? err.message : "Something went wrong");
      setLoadingPlan(null);
    }
  };

  if (!isLoaded) return null;

  // Not signed in
  if (!isSignedIn) {
    const planParam = searchParams.get("plan");
    const planLabel =
      planParam === "team"
        ? "Plot Team"
        : planParam === "pro"
          ? "Plot Pro"
          : planParam === "core"
            ? "Plot Core"
            : "Plot";
    const clerkRedirect =
      searchParams.get("sign_up_force_redirect_url") ||
      searchParams.get("sign_in_force_redirect_url") ||
      searchParams.get("sign_up_fallback_redirect_url") ||
      searchParams.get("sign_in_fallback_redirect_url");
    let returnUrl = `/upgrade${searchParams.toString() ? `?${searchParams.toString()}` : ""}`;
    if (clerkRedirect) {
      try {
        const url = new URL(clerkRedirect);
        returnUrl = url.pathname + url.search;
      } catch {
        returnUrl = clerkRedirect;
      }
    }

    return (
      <Container size="sm" mt="xl" mb="xl">
        <Stack gap="md" align="center" ta="center">
          <Title order={2}>Amplify your progress</Title>
          <Text c="dimmed">
            {expectedEmail
              ? `Sign in as ${expectedEmail} to upgrade to ${planLabel}.`
              : `Sign in to upgrade to ${planLabel}.`}
          </Text>
          <SignIn
            forceRedirectUrl={returnUrl}
            signUpForceRedirectUrl={returnUrl}
            initialValues={
              expectedEmail ? { emailAddress: expectedEmail } : undefined
            }
          />
        </Stack>
      </Container>
    );
  }

  // Loading (or waiting for signOut after detecting wrong Clerk account)
  if (loading || emailMismatch) {
    return (
      <Container size="sm" mt="xl" mb="xl">
        <Stack align="center" gap="md">
          <Loader />
          <Text c="dimmed">Loading plan...</Text>
        </Stack>
      </Container>
    );
  }

  const personalPlan = subscription?.plan ?? "free";
  const hasPersonalPaid =
    personalPlan !== "free" && subscription?.status === "active";
  const activeOrgs = (subscription?.teams ?? []).filter(
    (o) => o.plan !== "free" && o.status === "active",
  );
  const hasAnySubscription = hasPersonalPaid || activeOrgs.length > 0;

  const PLAN_TIER: Record<string, number> = {
    free: 0,
    core: 1,
    pro: 2,
    team: 3,
  };
  const personalTier = PLAN_TIER[personalPlan] ?? 0;

  // Success alert org name lookup
  const successOrg = successOrgId
    ? subscription?.teams?.find((o) => o.id === successOrgId)
    : null;

  const preselectedPlan = searchParams.get("plan");
  const corePlan = PLANS.find((p) => p.key === "core")!;
  const proPlan = PLANS.find((p) => p.key === "pro")!;
  const teamPlan = PLANS.find((p) => p.key === "team")!;

  const personalPlanButton = (planKey: "core" | "pro") => {
    const tier = PLAN_TIER[planKey];
    if (hasPersonalPaid && personalTier >= tier) {
      return {
        label:
          personalPlan === planKey ? "Current plan" : "Included in your plan",
        disabled: true,
      };
    }
    return {
      label: `Upgrade to ${planKey === "core" ? "Core" : "Pro"}`,
      disabled: false,
    };
  };

  return (
    <Container size="lg" mt="xl" mb="xl">
      <Stack gap="lg">
        <Stack align="center" ta="center" gap="xs">
          <Title order={2}>
            {hasAnySubscription ? "Your plans" : "Choose your plan"}
          </Title>
          <Text c="dimmed">
            {hasAnySubscription
              ? "Manage your subscriptions or add a new plan."
              : "Upgrade for unlimited connections."}
          </Text>
        </Stack>

        {isSuccess && (
          <Alert color="green" title="Plan active" mb="md">
            {successOrg
              ? `Your Team plan for ${successOrg.name} is now active.`
              : `Your plan is now active. Welcome to Plot ${personalPlan === "core" ? "Core" : "Pro"}!`}
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

        {/* Active subscriptions */}
        {hasAnySubscription && (
          <Stack gap="md">
            <Title order={4}>Active subscriptions</Title>
            <Box className={classes.subscriptionsList}>
              {hasPersonalPaid && (
                <Stack gap="xs">
                  <Box className={classes.currentPlan}>
                    <Text fw={600} size="lg" style={{ flex: 1 }}>
                      Plot {personalPlan === "core" ? "Core" : "Pro"}
                    </Text>
                    <Badge color="green" variant="light">
                      Active
                    </Badge>
                    <Button
                      onClick={() => handlePortal()}
                      loading={loadingPlan === "portal"}
                      variant="outline"
                      size="sm"
                    >
                      Manage plan
                    </Button>
                  </Box>
                  <Box className={classes.currentPlan}>
                    <Stack gap={2} style={{ flex: 1 }}>
                      <Text fw={600}>Connection add-ons</Text>
                      <Text c="dimmed" size="sm">
                        {addonCount} active · ${ADDON_PRICE}/mo each
                      </Text>
                    </Stack>
                    <Button
                      onClick={() => handleSetAddons(addonCount - 1)}
                      disabled={addonBusy || addonCount <= 0}
                      variant="outline"
                      size="sm"
                    >
                      Remove
                    </Button>
                    <Button
                      onClick={() => handleSetAddons(addonCount + 1)}
                      loading={addonBusy}
                      variant="outline"
                      size="sm"
                    >
                      Add
                    </Button>
                  </Box>
                </Stack>
              )}
              {activeOrgs.map((org) => (
                <Box key={org.id} className={classes.currentPlan}>
                  <Stack gap={2} style={{ flex: 1 }}>
                    <Text fw={600} size="lg">
                      Plot Team — {org.name}
                    </Text>
                    <Text c="dimmed" size="sm">
                      {org.memberCount}{" "}
                      {org.memberCount === 1 ? "member" : "members"}
                    </Text>
                  </Stack>
                  <Badge color="green" variant="light">
                    Active
                  </Badge>
                  {org.role === "admin" ? (
                    <Button
                      onClick={() => handlePortal(org.id)}
                      loading={loadingPlan === "portal"}
                      variant="outline"
                      size="sm"
                    >
                      Manage plan
                    </Button>
                  ) : (
                    <Button
                      component={Link}
                      to={`/team/${org.id}`}
                      variant="outline"
                      size="sm"
                    >
                      Manage team
                    </Button>
                  )}
                </Box>
              ))}
            </Box>
          </Stack>
        )}

        {/* Plan picker */}
        {hasAnySubscription && <Title order={4}>Add a plan</Title>}

        <Stack align="center">
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
              <Badge variant="light" color="green" size="sm">
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

        <Box className={classes.planGrid}>
          {/* Core */}
          <Stack
            className={
              preselectedPlan === "core"
                ? classes.planCardHighlight
                : classes.planCard
            }
            gap="md"
          >
            <Text className={classes.planName}>{corePlan.name}</Text>
            <Text className={classes.bestFor}>{corePlan.bestFor}</Text>
            <Stack gap="xs" className={classes.featureList}>
              {corePlan.features.map((f) => (
                <Box key={f} className={classes.featureItem}>
                  <IconCheck size={16} color="var(--mantine-color-brand-6)" />
                  <span>{f}</span>
                </Box>
              ))}
            </Stack>
            <Box className={classes.priceDivider} />
            <Box className={classes.priceBox}>
              <Text className={classes.planPrice}>${PRICES.core[billing]}</Text>
              <Text className={classes.planPricePeriod}>/mo</Text>
            </Box>
            {billing === "annual" && (
              <Text c="dimmed" size="xs" mt={-8}>
                Billed annually
              </Text>
            )}
            <Button
              onClick={() => handleCheckout("core")}
              loading={loadingPlan === "core"}
              disabled={personalPlanButton("core").disabled}
              fullWidth
            >
              {personalPlanButton("core").label}
            </Button>
          </Stack>

          {/* Pro */}
          <Stack
            className={
              preselectedPlan === "pro"
                ? classes.planCardHighlight
                : classes.planCard
            }
            gap="md"
          >
            <Text className={classes.planName}>{proPlan.name}</Text>
            <Text className={classes.bestFor}>{proPlan.bestFor}</Text>
            <Stack gap="xs" className={classes.featureList}>
              {proPlan.features.map((f) => (
                <Box key={f} className={classes.featureItem}>
                  <IconCheck size={16} color="var(--mantine-color-brand-6)" />
                  <span>{f}</span>
                </Box>
              ))}
            </Stack>
            <Box className={classes.priceDivider} />
            <Box className={classes.priceBox}>
              <Text className={classes.planPrice}>${PRICES.pro[billing]}</Text>
              <Text className={classes.planPricePeriod}>/mo</Text>
            </Box>
            {billing === "annual" && (
              <Text c="dimmed" size="xs" mt={-8}>
                Billed annually
              </Text>
            )}
            <Button
              onClick={() => handleCheckout("pro")}
              loading={loadingPlan === "pro"}
              disabled={personalPlanButton("pro").disabled}
              fullWidth
            >
              {personalPlanButton("pro").label}
            </Button>
          </Stack>

          {/* Team */}
          <Stack
            className={
              preselectedPlan === "team"
                ? classes.planCardHighlight
                : classes.planCard
            }
            gap="md"
          >
            <Text className={classes.planName}>{teamPlan.name}</Text>
            <Text className={classes.bestFor}>{teamPlan.bestFor}</Text>
            <Stack gap="xs" className={classes.featureList}>
              {teamPlan.features.map((f) => (
                <Box key={f} className={classes.featureItem}>
                  <IconCheck size={16} color="var(--mantine-color-brand-6)" />
                  <span>{f}</span>
                </Box>
              ))}
            </Stack>
            <Box className={classes.priceDivider} />
            <Select
              value={teamQuantity}
              onChange={(v) => v && setTeamQuantity(v)}
              data={QUANTITY_OPTIONS}
              size="sm"
            />
            <TextInput
              label="Team name"
              placeholder="Your company name"
              value={orgName}
              onChange={(e) => setOrgName(e.currentTarget.value)}
              size="sm"
            />
            {!isFreemailDomain && (
              <Checkbox
                label={
                  <span>
                    Allow anyone with an{" "}
                    <span style={{ fontWeight: 700 }}>@{emailDomain}</span>{" "}
                    email address to join
                  </span>
                }
                checked={domainAutoJoin}
                onChange={(e) => setDomainAutoJoin(e.currentTarget.checked)}
                size="sm"
              />
            )}
            <Box className={classes.priceDivider} />
            <Box className={classes.priceBox}>
              <Text className={classes.planPrice}>
                ${PRICES.team[billing] * (parseInt(teamQuantity) / 50)}
              </Text>
              <Text className={classes.planPricePeriod}>/mo</Text>
            </Box>
            {billing === "annual" && (
              <Text c="dimmed" size="xs" mt={-8}>
                Billed annually
              </Text>
            )}
            <Button
              onClick={() => handleCheckout("team")}
              loading={loadingPlan === "team"}
              fullWidth
            >
              Create Team
            </Button>
          </Stack>
        </Box>
      </Stack>
    </Container>
  );
}
