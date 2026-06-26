// NOTE: This page reflects the NEW pricing model — Free/Pro/Team, à-la-carte
// connection add-ons, and weighted automation capacity. The API mirror in
// `workers/api/src/utils/limits.ts` (`PLAN_LIMITS`) still encodes the OLD model
// and is updated by the product-changes work (Spec B,
// `docs/superpowers/specs/2026-06-26-pricing-model-product-changes-design.md`),
// NOT in this PR. Until that lands, the marketing page intentionally runs ahead
// of the backend. Tracked for extraction into a shared `@plot/plans` package.
//
// Core is being dropped: the pricing page hides it (filtered in pricing.tsx),
// but the `core` entry, `PRICES.core`, and the `PlanKey` value are RETAINED here
// so `upgrade.tsx` keeps building. Core's full removal (data + upgrade flow +
// PLAN_LIMITS + subscriber migration) is Spec B.

export type Billing = "monthly" | "annual";

export const PRICES = {
  core: { monthly: 15, annual: 12 },
  pro: { monthly: 25, annual: 20 },
  team: { monthly: 124, annual: 99 },
} as const;

/**
 * Price of one connection add-on, in USD/month. Every connection beyond a
 * plan's included pool is a $5/mo add-on; a few connectors (LinkedIn,
 * Instagram, WhatsApp) always require one. Add-ons are billed separately and do
 * NOT count toward a plan's included connections. (App Store buyers pay a higher
 * tier price to cover Apple's surcharge — see the StoreKit add-on tiers.)
 */
export const ADDON_PRICE = 5;

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
    bestFor: "For getting all your work into one place",
    price: () => "$0",
    priceNote: "Free forever",
    period: "",
    description: "The whole Plot platform, free forever.",
    features: [
      `Up to 2 connections ($${ADDON_PRICE}/mo each for more)`,
      "Automatic organization and prioritization",
      "Unlimited history and full search of everything in Plot",
      "Collaborate free with anyone on Plot",
      "Built-in Plot assistant (with some limits)",
      "1 automation",
      "Import 1 week of history from your connections",
    ],
    cta: "Get started",
    ctaLink: () => "/start",
    ctaVariant: "outline",
    highlight: false,
    badge: null,
    unit: null,
  },
  // RETAINED for upgrade.tsx only — hidden on the pricing page (filtered in
  // pricing.tsx). Core is being dropped; full removal is Spec B.
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
      `Connection add-ons $${ADDON_PRICE}/mo each`,
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
    bestFor: "For thriving across many tools",
    price: (billing) => `$${PRICES.pro[billing]}`,
    priceNote: null,
    period: "/mo",
    description: "Unlimited connections and more automation.",
    features: [
      "Unlimited connections",
      "Everything in Free",
      "Built-in Plot assistant",
      "10 automations",
      "No-code automation builder",
      "Import 1 year of history from your connections",
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
    bestFor: "For doing your team's best work together",
    price: (billing) => `$${PRICES.team[billing]}`,
    priceNote: null,
    period: "/mo",
    description: "Shared connections and automation for your whole team.",
    features: [
      "50 connections shared across your team (add as many as your team needs)",
      "Unlimited members — collaborate free",
      "Built-in Plot assistant",
      "10 automations per 50 connections",
      "No-code automation builder",
      "Import 1 year of history from your connections",
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
