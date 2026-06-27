// Plan + add-on pricing shared by the marketing pricing page (pricing.tsx) and
// the upgrade/checkout page (upgrade.tsx). The model is Free/Pro/Team with
// à-la-carte connection add-ons and weighted automation (twist) capacity.
//
// Numbers are imported from `@plotday/pricing` — the single source of truth
// shared with the API worker. Do NOT add local numeric literals; update
// `libs/pricing/src/index.ts` instead and rebuild.
//
// "Automation" is the marketing word for a twist; the page uses it because
// readers meet it before they learn the word "twist". (In product UI and code
// the add-on is the "twist add-on".) Core has been dropped from the model.
//
// Add-on availability: connection and twist add-ons are available on individual
// plans (Free and Pro). LinkedIn, Instagram, and WhatsApp always need a
// connection add-on on any plan.

import {
  CONNECTION_ADDON_PRICE,
  PLAN,
  PLAN_PRICES,
  TWIST_ADDON_PRICE,
} from "@plotday/pricing";

export type Billing = "monthly" | "annual";

export const PRICES = PLAN_PRICES;

/**
 * Price of one connection add-on, in USD/month. Every connection beyond a
 * plan's included pool is a $5/mo add-on; a few connectors (LinkedIn,
 * Instagram, WhatsApp) always require one. Add-ons are billed separately and do
 * NOT count toward a plan's included connections. (App Store buyers pay a higher
 * tier price to cover Apple's surcharge — see the StoreKit add-on tiers.)
 */
export const ADDON_PRICE = CONNECTION_ADDON_PRICE;

export { TWIST_ADDON_PRICE };

export type PlanKey = "free" | "pro" | "team";

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
      `${PLAN.free.twistCapacity} twist automation`,
      "Import 1 week of history from your connections",
    ],
    cta: "Get started",
    ctaLink: () => "/start",
    ctaVariant: "outline",
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
      `${PLAN.pro.twistCapacity} twist automations`,
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
      "50 connections or twist automations, shared across your team (add 50 more anytime)",
      "Unlimited members — collaborate free",
      "Built-in Plot assistant",
      "No-code automation builder",
      "Import 1 year of history from your connections",
      "Team-level controls",
    ],
    cta: "Get started",
    ctaLink: (billing) => `/upgrade?plan=team&billing=${billing}`,
    ctaVariant: "filled",
    highlight: false,
    badge: null,
    unit: "per 50 connections or twist automations",
  },
];
