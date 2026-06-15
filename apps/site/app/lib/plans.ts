// NOTE: Plan limits (regular and pro connections, twists, sync history)
// are also encoded in the API at `workers/api/src/utils/limits.ts`
// (`PLAN_LIMITS`). When changing the numbers here, update there in the same
// PR. Tracked for extraction into a shared `@plot/plans` package.

export type Billing = "monthly" | "annual";

export const PRICES = {
  core: { monthly: 15, annual: 12 },
  pro: { monthly: 25, annual: 20 },
  team: { monthly: 124, annual: 99 },
} as const;

export type PlanKey = "free" | "core" | "pro" | "team";

export interface Plan {
  key: PlanKey;
  name: string;
  bestFor: string;
  price: (billing: Billing) => string;
  priceNote: string | null;
  period: string;
  description: string;
  features: string[];
  cta: string;
  ctaLink: (billing: Billing) => string;
  ctaVariant: "outline" | "filled";
  highlight: boolean;
  badge: string | null;
  unit: string | null;
}

export const PLANS: Plan[] = [
  {
    key: "free",
    name: "Free",
    bestFor: "For individuals and teams using a few core tools",
    price: () => "$0",
    priceNote: "Free forever",
    period: "",
    description: "Make progress with unlimited collaborators.",
    features: [
      "Up to 2 connections",
      "1 Twist (automation or agent)",
      "Import 1 week of historical items from connections",
      "Automated organization and prioritization (limitations apply)",
      "Unlimited collaborators",
      "Full search and history of all your work in Plot",
    ],
    cta: "Get started",
    ctaLink: () => "/start",
    ctaVariant: "outline",
    highlight: false,
    badge: null,
    unit: null,
  },
  {
    key: "core",
    name: "Core",
    bestFor: "For individuals connecting a handful of tools",
    price: (billing) => `$${PRICES.core[billing]}`,
    priceNote: null,
    period: "/mo",
    description: "Increase your connections and automations.",
    features: [
      "Up to 5 connections",
      "2 Twists (automations and agents)",
      "Import 30 days of historical items from connections",
      "Automated organization and prioritization (expanded limits)",
      "Unlimited collaborators",
      "Full search and history of all your work in Plot",
    ],
    cta: "Get started",
    ctaLink: (billing) => `/upgrade?plan=core&billing=${billing}`,
    ctaVariant: "filled",
    highlight: false,
    badge: null,
    unit: null,
  },
  {
    key: "pro",
    name: "Pro",
    bestFor: "For individuals working across many tools",
    price: (billing) => `$${PRICES.pro[billing]}`,
    priceNote: null,
    period: "/mo",
    description:
      "Unlimited connections and automations. Bring all your tools into one place.",
    features: [
      "Unlimited connections",
      "Includes 1 Pro connection",
      "Unlimited Twists (optional AI usage extra)",
      "Import 1 year of historical items from connections",
      "No-code Twist builder",
      "Automated organization and prioritization (unlimited)",
      "Unlimited collaborators",
      "Full search and history of all your work in Plot",
    ],
    cta: "Get started",
    ctaLink: (billing) => `/upgrade?plan=pro&billing=${billing}`,
    ctaVariant: "filled",
    highlight: true,
    badge: null,
    unit: null,
  },
  {
    key: "team",
    name: "Team",
    bestFor: "For teams doing their best work together",
    price: (billing) => `$${PRICES.team[billing]}`,
    priceNote: null,
    period: "/mo",
    description:
      "Provide your teams with the connections and automations to do their best work.",
    features: [
      "50+ connections shared across your team",
      "Pro connections count as 3 from the pool",
      "Unlimited Twists (optional AI usage extra)",
      "Import 1 year of historical items from connections",
      "No-code Twist builder",
      "Automated organization and prioritization (unlimited)",
      "Unlimited team members",
      "Full search and history of all your work in Plot",
      "Team-level controls",
    ],
    cta: "Get started",
    ctaLink: (billing) => `/upgrade?plan=team&billing=${billing}`,
    ctaVariant: "filled",
    highlight: false,
    badge: null,
    unit: "per 50 connections",
  },
];
