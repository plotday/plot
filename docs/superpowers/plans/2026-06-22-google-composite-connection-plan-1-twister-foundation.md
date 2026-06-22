# Composite Connector Foundation (Twister) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add provider-agnostic `ProductModule` + `CompositeConnector` abstractions to the Twister SDK so several "product modules" (e.g. Google Mail/Calendar/Tasks/Contacts) can be composed behind a single connection (one OAuth, one charge), with pure, unit-tested logic for scope aggregation, channel-id namespacing, per-product enablement, and effective link types.

**Architecture:** Two new classes in `public/twister/src/`. `ProductModule<TSelf>` extends the existing `Tool<TSelf>` (so the runtime's per-`(twist_instance_id, tool-path)` isolation of state/callbacks/webhooks applies to each module for free in later plans). `CompositeConnector<TSelf>` extends the existing `Connector<TSelf>` and delegates the channel lifecycle to child modules, keyed by a stable product `key`. All decision logic lives in pure functions in `composite-routing.ts` so it is testable without the runtime. This plan is **Plan 1 of 4**; it touches only the Twister SDK and ships no Google-specific code.

**Tech Stack:** TypeScript (ESM, `strict`), Vitest 2 (added here — Twister has no test runner yet), pnpm workspace, Changesets.

## Global Constraints

- **Provider-agnostic.** Nothing in this plan may mention Google/Microsoft or any provider. The Google composite is Plan 2. (Spec: "None of these permission changes should be Google-specific.")
- **Channel-id namespacing uses a `:` prefix split on the FIRST `:` only** — `productKey` never contains `:`, but a provider `channelId` may (e.g. URLs, calendar ids). No DB schema change; `channel_id` stays opaque text. (Spec §2.3.)
- **Enablement predicate (exact):** `enabled(product) = product.requiredScopes ⊆ grantedScopes  AND  NOT locally-off  AND  (product.channelless OR enabledChannelCount > 0)`. (Spec §2.5.)
- **Products are optional scope groups.** Aggregated connection scopes are `{ required: [], optional: [oneGroupPerProduct] }`. (Spec §1.2, §2.3.)
- **Backwards compatibility:** do not change any existing `Connector`/`Tool`/`Twist` signature or exported symbol. Only add new files + new exports.
- **Twister changeset is mandatory** for any change under `public/twister/src/` (AGENTS.md). One changeset at `public/.changeset/`.
- **Do not override `scopes`/`linkTypes` as getters on the base** — TS forbids accessor-over-property and base field init runs before subclass `products` is set. Concrete subclasses (Plan 2) set them as plain readonly fields from a module-level product list using the helpers this plan exports.

---

### Task 1: Pure routing/aggregation core + Vitest scaffolding

**Files:**
- Create: `public/twister/src/product-module.ts` (types only in this task — `ProductDescriptor`, `ProductStatus`, `ProductStatusReason`)
- Create: `public/twister/src/composite-routing.ts`
- Create: `public/twister/src/composite-routing.test.ts`
- Create: `public/twister/vitest.config.ts`
- Modify: `public/twister/package.json` (add `test` script + `vitest` devDep)

**Interfaces:**
- Produces (consumed by Tasks 2–4 and Plan 2):
  - `type ProductDescriptor = { key: string; label: string; description: string; icon: string; channelNoun?: { singular: string; plural: string }; channelless?: boolean; requiredScopes: string[]; scopeGroup: OptionalScopeGroup; linkTypes: LinkTypeConfig[] }`
  - `type ProductStatusReason = "granted" | "scope-missing" | "locally-off" | "no-channels"`
  - `type ProductStatus = { key: string; enabled: boolean; reason: ProductStatusReason }`
  - `const CHANNEL_NS_SEP = ":"`
  - `namespaceChannelId(productKey: string, channelId: string): string`
  - `parseNamespacedChannelId(namespaced: string): { productKey: string; channelId: string }`
  - `namespaceChannelTree(productKey: string, channel: Channel): Channel`
  - `aggregateScopes(products: ProductDescriptor[]): ScopeConfig`
  - `selectGrantedProducts(products: ProductDescriptor[], grantedScopes: string[]): ProductDescriptor[]`
  - `isProductEnabled(product: ProductDescriptor, grantedScopes: string[], opts: { locallyOff: boolean; enabledChannelCount: number }): boolean`
  - `productStatus(product: ProductDescriptor, grantedScopes: string[], opts: { locallyOff: boolean; enabledChannelCount: number }): ProductStatus`
  - `effectiveLinkTypes(products: ProductDescriptor[], enabledKeys: Iterable<string>): LinkTypeConfig[]`
  - `productForLinkType(products: ProductDescriptor[], linkType: string): ProductDescriptor | null`

- [ ] **Step 1: Add Vitest to the Twister package**

Edit `public/twister/package.json`. In `"scripts"`, add a `test` entry (place it after `"clean"`):

```json
    "clean": "rm -rf dist bin",
    "test": "vitest run"
```

In `"devDependencies"`, add Vitest (match the version connectors use):

```json
    "typescript": "^5.9.3",
    "vitest": "^2.1.8"
```

- [ ] **Step 2: Create the Vitest config**

Create `public/twister/vitest.config.ts` (mirrors `public/connectors/google-calendar/vitest.config.ts`):

```ts
import { defineConfig } from "vitest/config";

export default defineConfig({
  resolve: {
    // Resolve workspace packages from their TypeScript source using the
    // @plotday/connector export condition (same as the build path).
    conditions: ["@plotday/connector", "default"],
  },
  test: {},
});
```

- [ ] **Step 3: Install the new dependency**

Run (from repo root): `pnpm install`
Expected: completes successfully; `public/twister/node_modules/.bin/vitest` exists.

- [ ] **Step 4: Define the product descriptor types**

Create `public/twister/src/product-module.ts` with ONLY the data types for now (the `ProductModule` class is added in Task 2):

```ts
import type { OptionalScopeGroup } from "./connector";
import type { LinkTypeConfig } from "./tools/integrations";

/**
 * Static, serializable description of one product within a composite
 * connection (e.g. "Mail", "Calendar"). Provider-agnostic.
 */
export type ProductDescriptor = {
  /** Stable product id, e.g. "mail". Used for channel namespacing and status.
   *  NOTE: this is the descriptor key, NOT necessarily the build()/tool name
   *  (which must avoid colliding with built-in tools like "tasks"). */
  key: string;
  /** Setup-screen product name, e.g. "Mail". */
  label: string;
  /** Setup-screen one-line explanation of what enabling this product does. */
  description: string;
  /** Logo URL for the product row. */
  icon: string;
  /** What this product's channels are called (folders, calendars, labels…). */
  channelNoun?: { singular: string; plural: string };
  /** True when the product has no channels (e.g. Contacts). */
  channelless?: boolean;
  /** Minimum scopes that must be granted for this product to count enabled. */
  requiredScopes: string[];
  /** The optional scope group requested for this product at consent time.
   *  Convention: `scopeGroup.id === key`. */
  scopeGroup: OptionalScopeGroup;
  /** Link types this product contributes to the connection (may be empty). */
  linkTypes: LinkTypeConfig[];
};

/** Why a product is or isn't enabled — surfaced to the status modal. */
export type ProductStatusReason =
  | "granted"
  | "scope-missing"
  | "locally-off"
  | "no-channels";

/** Derived per-product status for the post-auth status screen. */
export type ProductStatus = {
  key: string;
  enabled: boolean;
  reason: ProductStatusReason;
};
```

- [ ] **Step 5: Write the failing test for the pure functions**

Create `public/twister/src/composite-routing.test.ts`:

```ts
import { describe, expect, it } from "vitest";

import type { ProductDescriptor } from "./product-module";
import {
  aggregateScopes,
  CHANNEL_NS_SEP,
  effectiveLinkTypes,
  isProductEnabled,
  namespaceChannelId,
  namespaceChannelTree,
  parseNamespacedChannelId,
  productForLinkType,
  productStatus,
  selectGrantedProducts,
} from "./composite-routing";

const mail: ProductDescriptor = {
  key: "mail",
  label: "Mail",
  description: "Email",
  icon: "mail.svg",
  requiredScopes: ["scope.mail"],
  scopeGroup: { id: "mail", label: "Mail", scopes: ["scope.mail"], default: true },
  linkTypes: [{ type: "email", label: "Email" }],
};
const calendar: ProductDescriptor = {
  key: "calendar",
  label: "Calendar",
  description: "Calendar",
  icon: "cal.svg",
  requiredScopes: ["scope.cal"],
  scopeGroup: {
    id: "calendar",
    label: "Calendar",
    scopes: ["scope.cal", "scope.cal.list"],
    default: true,
  },
  linkTypes: [{ type: "event", label: "Event", includesSchedules: true }],
};
const contacts: ProductDescriptor = {
  key: "contacts",
  label: "Contacts",
  description: "Contacts",
  icon: "contacts.svg",
  channelless: true,
  requiredScopes: ["scope.contacts"],
  scopeGroup: { id: "contacts", label: "Contacts", scopes: ["scope.contacts"], default: true },
  linkTypes: [],
};
const PRODUCTS = [mail, calendar, contacts];

describe("channel id namespacing", () => {
  it("prefixes the product key", () => {
    expect(namespaceChannelId("calendar", "primary")).toBe(`calendar${CHANNEL_NS_SEP}primary`);
  });

  it("round-trips ids that themselves contain the separator", () => {
    const id = "https://mail.google.com/u/0#inbox/abc";
    const ns = namespaceChannelId("mail", id);
    expect(parseNamespacedChannelId(ns)).toEqual({ productKey: "mail", channelId: id });
  });

  it("throws on a non-namespaced id", () => {
    expect(() => parseNamespacedChannelId("primary")).toThrow();
  });

  it("namespaces a channel tree including children", () => {
    const tree = namespaceChannelTree("drive", {
      id: "root",
      title: "My Drive",
      children: [{ id: "sub", title: "Sub" }],
    });
    expect(tree.id).toBe("drive:root");
    expect(tree.children?.[0].id).toBe("drive:sub");
  });
});

describe("aggregateScopes", () => {
  it("puts every product's scope group under optional, with empty required", () => {
    expect(aggregateScopes(PRODUCTS)).toEqual({
      required: [],
      optional: [mail.scopeGroup, calendar.scopeGroup, contacts.scopeGroup],
    });
  });
});

describe("selectGrantedProducts", () => {
  it("keeps only products whose required scopes are all granted", () => {
    expect(selectGrantedProducts(PRODUCTS, ["scope.mail", "scope.contacts"])).toEqual([
      mail,
      contacts,
    ]);
  });
});

describe("isProductEnabled", () => {
  it("false when a required scope is missing", () => {
    expect(isProductEnabled(calendar, ["scope.mail"], { locallyOff: false, enabledChannelCount: 1 })).toBe(false);
  });
  it("false when locally turned off", () => {
    expect(isProductEnabled(calendar, ["scope.cal"], { locallyOff: true, enabledChannelCount: 1 })).toBe(false);
  });
  it("false when channel-bearing product has no enabled channels", () => {
    expect(isProductEnabled(calendar, ["scope.cal"], { locallyOff: false, enabledChannelCount: 0 })).toBe(false);
  });
  it("true for a channelless product with the scope granted", () => {
    expect(isProductEnabled(contacts, ["scope.contacts"], { locallyOff: false, enabledChannelCount: 0 })).toBe(true);
  });
  it("true for a channel product with scope + an enabled channel", () => {
    expect(isProductEnabled(calendar, ["scope.cal"], { locallyOff: false, enabledChannelCount: 2 })).toBe(true);
  });
});

describe("productStatus", () => {
  it("reports the specific reason", () => {
    expect(productStatus(calendar, [], { locallyOff: false, enabledChannelCount: 0 }).reason).toBe("scope-missing");
    expect(productStatus(calendar, ["scope.cal"], { locallyOff: true, enabledChannelCount: 1 }).reason).toBe("locally-off");
    expect(productStatus(calendar, ["scope.cal"], { locallyOff: false, enabledChannelCount: 0 }).reason).toBe("no-channels");
    const ok = productStatus(calendar, ["scope.cal"], { locallyOff: false, enabledChannelCount: 1 });
    expect(ok).toEqual({ key: "calendar", enabled: true, reason: "granted" });
  });
});

describe("effectiveLinkTypes", () => {
  it("unions link types over enabled products only", () => {
    expect(effectiveLinkTypes(PRODUCTS, ["mail"])).toEqual(mail.linkTypes);
    expect(effectiveLinkTypes(PRODUCTS, ["calendar"])).toEqual(calendar.linkTypes);
    expect(effectiveLinkTypes(PRODUCTS, ["mail", "calendar"])).toEqual([
      ...mail.linkTypes,
      ...calendar.linkTypes,
    ]);
    expect(effectiveLinkTypes(PRODUCTS, [])).toEqual([]);
  });
});

describe("productForLinkType", () => {
  it("finds the product owning a link type, else null", () => {
    expect(productForLinkType(PRODUCTS, "event")).toBe(calendar);
    expect(productForLinkType(PRODUCTS, "nope")).toBeNull();
  });
});
```

- [ ] **Step 6: Run the test to verify it fails**

Run: `cd public/twister && pnpm exec vitest run src/composite-routing.test.ts`
Expected: FAIL — `Failed to resolve import "./composite-routing"` (file does not exist yet).

- [ ] **Step 7: Implement the pure functions**

Create `public/twister/src/composite-routing.ts`:

```ts
import type { ScopeConfig } from "./connector";
import type { ProductDescriptor, ProductStatus } from "./product-module";
import type { Channel, LinkTypeConfig } from "./tools/integrations";

/** Separator between a product key and a provider channel id. */
export const CHANNEL_NS_SEP = ":";

/** `("calendar", "primary") -> "calendar:primary"`. */
export function namespaceChannelId(productKey: string, channelId: string): string {
  return `${productKey}${CHANNEL_NS_SEP}${channelId}`;
}

/**
 * Inverse of {@link namespaceChannelId}. Splits on the FIRST separator only,
 * so provider channel ids that themselves contain `:` round-trip intact.
 */
export function parseNamespacedChannelId(namespaced: string): {
  productKey: string;
  channelId: string;
} {
  const i = namespaced.indexOf(CHANNEL_NS_SEP);
  if (i === -1) {
    throw new Error(`Channel id "${namespaced}" is not namespaced with a product key`);
  }
  return {
    productKey: namespaced.slice(0, i),
    channelId: namespaced.slice(i + CHANNEL_NS_SEP.length),
  };
}

/** Namespaces a channel and (recursively) its children under one product key. */
export function namespaceChannelTree(productKey: string, channel: Channel): Channel {
  return {
    ...channel,
    id: namespaceChannelId(productKey, channel.id),
    ...(channel.children
      ? { children: channel.children.map((c) => namespaceChannelTree(productKey, c)) }
      : {}),
  };
}

/** Connection scopes: every product is one optional group; nothing is required. */
export function aggregateScopes(products: ProductDescriptor[]): ScopeConfig {
  return { required: [], optional: products.map((p) => p.scopeGroup) };
}

/** Products whose `requiredScopes` are all present in `grantedScopes`. */
export function selectGrantedProducts(
  products: ProductDescriptor[],
  grantedScopes: string[],
): ProductDescriptor[] {
  const granted = new Set(grantedScopes);
  return products.filter((p) => p.requiredScopes.every((s) => granted.has(s)));
}

/**
 * The canonical enablement predicate (see plan Global Constraints):
 * required scopes granted AND not locally off AND (channelless OR has channels).
 */
export function isProductEnabled(
  product: ProductDescriptor,
  grantedScopes: string[],
  opts: { locallyOff: boolean; enabledChannelCount: number },
): boolean {
  const granted = new Set(grantedScopes);
  if (!product.requiredScopes.every((s) => granted.has(s))) return false;
  if (opts.locallyOff) return false;
  if (product.channelless) return true;
  return opts.enabledChannelCount > 0;
}

/** Derives the per-product status (and the specific reason) for the status modal. */
export function productStatus(
  product: ProductDescriptor,
  grantedScopes: string[],
  opts: { locallyOff: boolean; enabledChannelCount: number },
): ProductStatus {
  const granted = new Set(grantedScopes);
  if (!product.requiredScopes.every((s) => granted.has(s))) {
    return { key: product.key, enabled: false, reason: "scope-missing" };
  }
  if (opts.locallyOff) {
    return { key: product.key, enabled: false, reason: "locally-off" };
  }
  if (!product.channelless && opts.enabledChannelCount === 0) {
    return { key: product.key, enabled: false, reason: "no-channels" };
  }
  return { key: product.key, enabled: true, reason: "granted" };
}

/** Union of link types over the currently-enabled products, in product order. */
export function effectiveLinkTypes(
  products: ProductDescriptor[],
  enabledKeys: Iterable<string>,
): LinkTypeConfig[] {
  const enabled = new Set(enabledKeys);
  return products.filter((p) => enabled.has(p.key)).flatMap((p) => p.linkTypes);
}

/** The product that declares a given link type, or null. */
export function productForLinkType(
  products: ProductDescriptor[],
  linkType: string,
): ProductDescriptor | null {
  return products.find((p) => p.linkTypes.some((lt) => lt.type === linkType)) ?? null;
}
```

- [ ] **Step 8: Run the test to verify it passes**

Run: `cd public/twister && pnpm exec vitest run src/composite-routing.test.ts`
Expected: PASS (all assertions green).

- [ ] **Step 9: Type-check**

Run: `cd public/twister && pnpm lint`
Expected: no errors (`tsc --noEmit` over `src/**/*.ts`).

- [ ] **Step 10: Commit**

```bash
git add public/twister/package.json public/twister/vitest.config.ts \
  public/twister/src/product-module.ts public/twister/src/composite-routing.ts \
  public/twister/src/composite-routing.test.ts pnpm-lock.yaml
git commit -m "feat(twister): composite-connection routing core + vitest scaffolding"
```

---

### Task 2: `ProductModule` abstract class

**Files:**
- Modify: `public/twister/src/product-module.ts` (append the class)
- Create: `public/twister/src/product-module.test.ts`

**Interfaces:**
- Consumes: `Tool<TSelf>` (`./tool`), `ProductDescriptor` (Task 1), connector/plot/integration types.
- Produces: `abstract class ProductModule<TSelf> extends Tool<TSelf>` with `abstract readonly descriptor: ProductDescriptor`, abstract `getChannels(token: AuthToken): Promise<Channel[]>`, `onChannelEnabled(channel: Channel, context?: SyncContext): Promise<void>`, `onChannelDisabled(channel: Channel): Promise<void>`, and overridable no-op write-back hooks mirroring `Connector`.

- [ ] **Step 1: Write the failing test**

Create `public/twister/src/product-module.test.ts`:

```ts
import { describe, expect, it, vi } from "vitest";

import { ProductModule, type ProductDescriptor } from "./product-module";
import type { Channel } from "./tools/integrations";
import type { ToolShed } from "./utils/types";

const descriptor: ProductDescriptor = {
  key: "mail",
  label: "Mail",
  description: "Email",
  icon: "mail.svg",
  requiredScopes: ["scope.mail"],
  scopeGroup: { id: "mail", label: "Mail", scopes: ["scope.mail"], default: true },
  linkTypes: [{ type: "email", label: "Email" }],
};

class FakeMail extends ProductModule<FakeMail> {
  readonly descriptor = descriptor;
  enabled: string[] = [];
  build() {
    return {};
  }
  async getChannels(): Promise<Channel[]> {
    return [{ id: "INBOX", title: "Inbox" }];
  }
  async onChannelEnabled(channel: Channel): Promise<void> {
    this.enabled.push(channel.id);
  }
  async onChannelDisabled(): Promise<void> {}
}

const fakeShed = {
  build: vi.fn(),
  ready: true,
  waitForReady: async () => {},
  getTools: () => ({}),
} as unknown as ToolShed;

describe("ProductModule", () => {
  it("exposes its descriptor and channel methods", async () => {
    const mod = new FakeMail("mail", {} as never, fakeShed);
    expect(mod.descriptor.key).toBe("mail");
    expect(await mod.getChannels()).toEqual([{ id: "INBOX", title: "Inbox" }]);
    await mod.onChannelEnabled({ id: "INBOX", title: "Inbox" });
    expect(mod.enabled).toEqual(["INBOX"]);
  });

  it("provides no-op write-back hooks by default", async () => {
    const mod = new FakeMail("mail", {} as never, fakeShed);
    await expect(mod.onNoteCreated({} as never, {} as never)).resolves.toBeUndefined();
    await expect(mod.onLinkUpdated({} as never)).resolves.toBeUndefined();
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd public/twister && pnpm exec vitest run src/product-module.test.ts`
Expected: FAIL — `ProductModule` is not exported (only the types exist).

- [ ] **Step 3: Implement the class**

Append to `public/twister/src/product-module.ts`. First extend the import block at the top of the file to add the runtime/type imports the class needs:

```ts
import type {
  CreateLinkDraft,
  NoteWriteBackResult,
  OptionalScopeGroup,
} from "./connector";
import type {
  Actor,
  ActorId,
  Contact,
  Link,
  NewLinkWithNotes,
  Note,
  Thread,
} from "./plot";
import type { ScheduleContactStatus } from "./schedule";
import { Tool } from "./tool";
import type {
  AuthToken,
  Channel,
  LinkTypeConfig,
  SyncContext,
} from "./tools/integrations";
```

(Remove the now-duplicated single-line `OptionalScopeGroup`/`LinkTypeConfig` imports added in Task 1 so each symbol is imported once.)

Then append the class after the existing type declarations:

```ts
/**
 * One product inside a {@link CompositeConnector}. A `ProductModule` is "a
 * connector minus the account/billing/OAuth shell": it owns its channels,
 * link types, sync, and write-back, but the composite owns the single OAuth
 * connection and one charge.
 *
 * Extends {@link Tool} so the runtime isolates each module's state, scheduled
 * callbacks, and webhooks by tool path — modules cannot collide.
 *
 * The write-back hooks mirror {@link Connector}'s and default to no-ops; the
 * composite routes the relevant dispatch to the owning module (wired in a
 * later plan). Provider-agnostic.
 */
export abstract class ProductModule<TSelf> extends Tool<TSelf> {
  /** Static description of this product (key, label, scopes, link types…). */
  abstract readonly descriptor: ProductDescriptor;

  /** List this product's channels for the authorized account. Ids are bare
   *  (un-namespaced); the composite namespaces them. */
  abstract getChannels(token: AuthToken): Promise<Channel[]>;

  /** Begin syncing a channel (queue work via this.runTask; see Connector). */
  abstract onChannelEnabled(channel: Channel, context?: SyncContext): Promise<void>;

  /** Stop syncing a channel; tear down webhooks and per-channel state. */
  abstract onChannelDisabled(channel: Channel): Promise<void>;

  // ---- Write-back hooks (optional; default no-ops — mirror Connector) ----
  /* eslint-disable @typescript-eslint/no-unused-vars */
  onLinkUpdated(link: Link): Promise<void> {
    return Promise.resolve();
  }
  onCreateLink(draft: CreateLinkDraft): Promise<NewLinkWithNotes | null> {
    return Promise.resolve(null);
  }
  onNoteCreated(note: Note, thread: Thread): Promise<string | NoteWriteBackResult | void> {
    return Promise.resolve();
  }
  onNoteUpdated(note: Note, thread: Thread): Promise<NoteWriteBackResult | void> {
    return Promise.resolve();
  }
  onThreadRead(thread: Thread, actor: Actor, unread: boolean): Promise<void> {
    return Promise.resolve();
  }
  onThreadToDo(thread: Thread, actor: Actor, todo: boolean, options: { date?: Date }): Promise<void> {
    return Promise.resolve();
  }
  onContactsChanged(
    thread: Thread,
    changes: {
      added: Array<{ contact: Contact; role: string | null }>;
      removed: Array<{ contact: Contact; role: string | null }>;
      changed: Array<{ contact: Contact; from: string | null; to: string | null }>;
    },
  ): Promise<void> {
    return Promise.resolve();
  }
  onScheduleContactUpdated(
    thread: Thread,
    scheduleId: string,
    contactId: ActorId,
    status: ScheduleContactStatus | null,
    actor: Actor,
  ): Promise<void> {
    return Promise.resolve();
  }
  onNoteReactionChanged(
    note: Note,
    thread: Thread,
    actor: Actor,
    emoji: string,
    added: boolean,
  ): Promise<void> {
    return Promise.resolve();
  }
  /* eslint-enable @typescript-eslint/no-unused-vars */
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd public/twister && pnpm exec vitest run src/product-module.test.ts`
Expected: PASS.

- [ ] **Step 5: Type-check**

Run: `cd public/twister && pnpm lint`
Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add public/twister/src/product-module.ts public/twister/src/product-module.test.ts
git commit -m "feat(twister): ProductModule abstract class"
```

---

### Task 3: `CompositeConnector` abstract class

**Files:**
- Create: `public/twister/src/composite-connector.ts`
- Create: `public/twister/src/composite-connector.test.ts`

**Interfaces:**
- Consumes: `Connector` + `ScopeConfig` (`./connector`), Task 1 routing functions, `ProductModule` + `ProductDescriptor` + `ProductStatus` (Tasks 1–2), integration types.
- Produces: `abstract class CompositeConnector<TSelf> extends Connector<TSelf>` with:
  - `abstract readonly products: ProductDescriptor[]`
  - `protected abstract modules(): Record<string, ProductModule<unknown>>` (descriptor key → built module instance; keys may differ from build/tool names to dodge built-in collisions like `tasks`)
  - `effectiveLinkTypes(enabledKeys: Iterable<string>): LinkTypeConfig[]`
  - `productStatuses(grantedScopes: string[], state: { locallyOff: ReadonlySet<string>; enabledChannelCount: (key: string) => number }): ProductStatus[]`
  - implementations of `getChannels`, `onChannelEnabled`, `onChannelDisabled` that delegate to modules.

- [ ] **Step 1: Write the failing test**

Create `public/twister/src/composite-connector.test.ts`:

```ts
import { describe, expect, it, vi } from "vitest";

import { aggregateScopes } from "./composite-routing";
import { CompositeConnector } from "./composite-connector";
import type { ProductDescriptor, ProductModule } from "./product-module";
import type { Uuid } from "./plot";
import { AuthProvider, type AuthToken, type Channel } from "./tools/integrations";
import type { ToolShed } from "./utils/types";

const mail: ProductDescriptor = {
  key: "mail",
  label: "Mail",
  description: "Email",
  icon: "mail.svg",
  requiredScopes: ["scope.mail"],
  scopeGroup: { id: "mail", label: "Mail", scopes: ["scope.mail"], default: true },
  linkTypes: [{ type: "email", label: "Email" }],
};
const calendar: ProductDescriptor = {
  key: "calendar",
  label: "Calendar",
  description: "Calendar",
  icon: "cal.svg",
  requiredScopes: ["scope.cal"],
  scopeGroup: { id: "calendar", label: "Calendar", scopes: ["scope.cal"], default: true },
  linkTypes: [{ type: "event", label: "Event", includesSchedules: true }],
};
const PRODUCTS = [mail, calendar];

function stubModule(channels: Channel[]) {
  return {
    getChannels: vi.fn(async () => channels),
    onChannelEnabled: vi.fn(async () => {}),
    onChannelDisabled: vi.fn(async () => {}),
  } as unknown as ProductModule<unknown> & {
    getChannels: ReturnType<typeof vi.fn>;
    onChannelEnabled: ReturnType<typeof vi.fn>;
    onChannelDisabled: ReturnType<typeof vi.fn>;
  };
}

const mailMod = stubModule([{ id: "INBOX", title: "Inbox" }]);
const calMod = stubModule([{ id: "primary", title: "Calendar" }]);

class TestComposite extends CompositeConnector<TestComposite> {
  readonly provider = AuthProvider.Google;
  readonly products = PRODUCTS;
  readonly scopes = aggregateScopes(PRODUCTS);
  readonly linkTypes = PRODUCTS.flatMap((p) => p.linkTypes);
  build() {
    return {};
  }
  protected modules(): Record<string, ProductModule<unknown>> {
    return { mail: mailMod, calendar: calMod };
  }
}

const fakeShed = {
  build: vi.fn(),
  ready: true,
  waitForReady: async () => {},
  getTools: () => ({}),
} as unknown as ToolShed;

function make() {
  return new TestComposite("twist-1" as Uuid, fakeShed);
}

const token = (scopes: string[]): AuthToken => ({ token: "t", scopes });

describe("CompositeConnector.getChannels", () => {
  it("returns namespaced channels from granted products only", async () => {
    const c = make();
    const channels = await c.getChannels(null, token(["scope.mail"]));
    expect(channels).toEqual([{ id: "mail:INBOX", title: "Inbox" }]);
    expect(calMod.getChannels).not.toHaveBeenCalled();
  });

  it("includes both products when both scopes granted", async () => {
    const c = make();
    const channels = await c.getChannels(null, token(["scope.mail", "scope.cal"]));
    expect(channels.map((ch) => ch.id)).toEqual(["mail:INBOX", "calendar:primary"]);
  });

  it("returns [] with no token", async () => {
    expect(await make().getChannels(null, null)).toEqual([]);
  });
});

describe("CompositeConnector channel lifecycle routing", () => {
  it("routes onChannelEnabled to the owning module with a bare id", async () => {
    const c = make();
    await c.onChannelEnabled({ id: "calendar:primary", title: "Calendar" });
    expect(calMod.onChannelEnabled).toHaveBeenCalledWith(
      { id: "primary", title: "Calendar" },
      undefined,
    );
    expect(mailMod.onChannelEnabled).not.toHaveBeenCalled();
  });

  it("routes onChannelDisabled to the owning module", async () => {
    const c = make();
    await c.onChannelDisabled({ id: "mail:INBOX", title: "Inbox" });
    expect(mailMod.onChannelDisabled).toHaveBeenCalledWith({ id: "INBOX", title: "Inbox" });
  });
});

describe("CompositeConnector derived views", () => {
  it("aggregates scopes as optional groups", () => {
    expect(make().scopes).toEqual({
      required: [],
      optional: [mail.scopeGroup, calendar.scopeGroup],
    });
  });

  it("effectiveLinkTypes unions enabled products only", () => {
    expect(make().effectiveLinkTypes(["calendar"])).toEqual(calendar.linkTypes);
  });

  it("productStatuses reports per-product enablement", () => {
    const statuses = make().productStatuses(["scope.mail"], {
      locallyOff: new Set(),
      enabledChannelCount: (key) => (key === "mail" ? 1 : 0),
    });
    expect(statuses).toEqual([
      { key: "mail", enabled: true, reason: "granted" },
      { key: "calendar", enabled: false, reason: "scope-missing" },
    ]);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd public/twister && pnpm exec vitest run src/composite-connector.test.ts`
Expected: FAIL — `Failed to resolve import "./composite-connector"`.

- [ ] **Step 3: Implement the class**

Create `public/twister/src/composite-connector.ts`:

```ts
import { Connector } from "./connector";
import {
  aggregateScopes,
  effectiveLinkTypes,
  namespaceChannelTree,
  parseNamespacedChannelId,
  productStatus,
  selectGrantedProducts,
} from "./composite-routing";
import type { ProductDescriptor, ProductModule, ProductStatus } from "./product-module";
import type {
  AuthToken,
  Authorization,
  Channel,
  LinkTypeConfig,
  SyncContext,
} from "./tools/integrations";

/**
 * A single connection that composes several {@link ProductModule}s (e.g.
 * Mail/Calendar/Tasks/Contacts) behind one OAuth provider and one charge.
 * Provider-agnostic: concrete subclasses (Google, later Microsoft) declare
 * `provider`, a product list, and a `modules()` map.
 *
 * Concrete subclasses set `scopes` and `linkTypes` as plain readonly fields
 * from their product list using {@link aggregateScopes}/`flatMap` — do NOT
 * override them as getters here (TS forbids accessor-over-property and base
 * field init runs before the subclass sets `products`):
 *
 * ```ts
 * const PRODUCTS = [Mail, Calendar, Tasks, Contacts];
 * class GoogleConnector extends CompositeConnector<GoogleConnector> {
 *   readonly provider = AuthProvider.Google;
 *   readonly products = PRODUCTS;
 *   readonly scopes = aggregateScopes(PRODUCTS);
 *   readonly linkTypes = PRODUCTS.flatMap((p) => p.linkTypes);
 *   build(build) { return { mail: build(GoogleMail), …, gtasks: build(GoogleTasks) }; }
 *   protected modules() {
 *     return { mail: this.tools.mail, calendar: this.tools.calendar,
 *              tasks: this.tools.gtasks, contacts: this.tools.contacts };
 *   }
 * }
 * ```
 */
export abstract class CompositeConnector<TSelf> extends Connector<TSelf> {
  /** Ordered product descriptors composing this connection. */
  abstract readonly products: ProductDescriptor[];

  /**
   * Maps each product descriptor `key` to its built child module instance.
   * Subclasses read from `this.tools` — the build()/tool name may differ from
   * the descriptor key to avoid colliding with built-in tools (e.g. `tasks`).
   */
  protected abstract modules(): Record<string, ProductModule<unknown>>;

  /** Link types for the currently-enabled products (per-instance; the API
   *  persists this to `twist_instance` so the client's has-calendar logic and
   *  agenda gating stay correct). */
  effectiveLinkTypes(enabledKeys: Iterable<string>): LinkTypeConfig[] {
    return effectiveLinkTypes(this.products, enabledKeys);
  }

  /** Per-product enabled/not-enabled status (+ reason) for the status modal. */
  productStatuses(
    grantedScopes: string[],
    state: { locallyOff: ReadonlySet<string>; enabledChannelCount: (key: string) => number },
  ): ProductStatus[] {
    return this.products.map((p) =>
      productStatus(p, grantedScopes, {
        locallyOff: state.locallyOff.has(p.key),
        enabledChannelCount: state.enabledChannelCount(p.key),
      }),
    );
  }

  protected moduleFor(key: string): ProductModule<unknown> {
    const mod = this.modules()[key];
    if (!mod) {
      throw new Error(`No product module registered for key "${key}"`);
    }
    return mod;
  }

  async getChannels(
    _auth: Authorization | null,
    token: AuthToken | null,
  ): Promise<Channel[]> {
    if (!token) return [];
    const all: Channel[] = [];
    for (const product of selectGrantedProducts(this.products, token.scopes)) {
      const channels = await this.moduleFor(product.key).getChannels(token);
      for (const channel of channels) {
        all.push(namespaceChannelTree(product.key, channel));
      }
    }
    return all;
  }

  async onChannelEnabled(channel: Channel, context?: SyncContext): Promise<void> {
    const { productKey, channelId } = parseNamespacedChannelId(channel.id);
    await this.moduleFor(productKey).onChannelEnabled({ ...channel, id: channelId }, context);
  }

  async onChannelDisabled(channel: Channel): Promise<void> {
    const { productKey, channelId } = parseNamespacedChannelId(channel.id);
    await this.moduleFor(productKey).onChannelDisabled({ ...channel, id: channelId });
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd public/twister && pnpm exec vitest run src/composite-connector.test.ts`
Expected: PASS.

- [ ] **Step 5: Type-check**

Run: `cd public/twister && pnpm lint`
Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add public/twister/src/composite-connector.ts public/twister/src/composite-connector.test.ts
git commit -m "feat(twister): CompositeConnector abstract class with module delegation"
```

---

### Task 4: Exports, changeset, and full verification

**Files:**
- Modify: `public/twister/src/index.ts`
- Create: `public/.changeset/composite-connector.md`

**Interfaces:**
- Produces: `@plotday/twister` top-level re-exports of `ProductModule`, `ProductDescriptor`, `ProductStatus`, `ProductStatusReason`, `CompositeConnector`, and all `composite-routing` helpers — so Plan 2's `GoogleConnector` can `import { CompositeConnector, ProductModule, aggregateScopes } from "@plotday/twister"`.

- [ ] **Step 1: Add the new modules to the barrel export**

Edit `public/twister/src/index.ts`. After the existing `export * from "./connector";` line, add:

```ts
export * from "./product-module";
export * from "./composite-connector";
export * from "./composite-routing";
```

- [ ] **Step 2: Write the failing export test**

Create the assertion as a quick check appended to `public/twister/src/composite-connector.test.ts` (re-uses the configured runner). Add at the bottom:

```ts
describe("package exports", () => {
  it("re-exports the new symbols from the barrel", async () => {
    const api = await import("./index");
    expect(typeof api.CompositeConnector).toBe("function");
    expect(typeof api.ProductModule).toBe("function");
    expect(typeof api.aggregateScopes).toBe("function");
  });
});
```

- [ ] **Step 3: Run it to verify it fails, then passes after Step 1**

Run: `cd public/twister && pnpm exec vitest run src/composite-connector.test.ts`
Expected: PASS once Step 1's edit is in place (FAIL — `api.CompositeConnector` undefined — if the export lines are missing). If you did Step 1 first, confirm PASS.

- [ ] **Step 4: Add the changeset**

Create `public/.changeset/composite-connector.md`:

```markdown
---
"@plotday/twister": minor
---

Added: CompositeConnector + ProductModule — compose multiple product modules behind a single connection (one OAuth, one charge), with per-product optional scope groups, channel-id namespacing, derived per-product enablement/status, and effective link types from enabled products. Provider-agnostic foundation reused for Google and Microsoft.
```

- [ ] **Step 5: Validate the changeset**

Run: `cd public && pnpm validate-changesets`
Expected: passes (no errors).

- [ ] **Step 6: Full type-check, test, and build**

Run: `cd public/twister && pnpm lint && pnpm exec vitest run && pnpm build:builder`
Expected: lint clean; all test files pass; `build:builder` succeeds and (per `tsconfig.build.json` excluding `**/*.test.ts`) emits `dist/composite-connector.js`, `dist/product-module.js`, `dist/composite-routing.js` but NO `*.test.js`.

- [ ] **Step 7: Verify the workspace consumer still type-checks**

Run (from repo root): `pnpm --filter @plotday/connector-google-calendar lint`
Expected: no errors — confirms the new exports don't break an existing connector that imports `@plotday/twister`.

- [ ] **Step 8: Commit**

```bash
git add public/twister/src/index.ts public/twister/src/composite-connector.test.ts \
  public/.changeset/composite-connector.md
git commit -m "feat(twister): export composite-connection API + changeset"
```

---

## Self-Review

**1. Spec coverage (Plan 1 scope only — the SDK foundation):**
- Single connection / one charge → enabled by `CompositeConnector` being one `Connector` (one twist_instance). ✓ (billing wiring is Plan 2, unchanged code path)
- Products as optional scope groups → `aggregateScopes` (Task 1). ✓
- Channel namespacing, no schema change → `namespaceChannelId`/`parse`/`namespaceChannelTree` + delegation (Tasks 1, 3). ✓
- Enablement predicate → `isProductEnabled`/`productStatus` (Task 1), surfaced via `productStatuses` (Task 3). ✓
- Effective link types from enabled products (drives agenda gating) → `effectiveLinkTypes` (Tasks 1, 3). ✓
- Provider-agnostic / Microsoft-ready → no provider names in any file; concrete subclass pattern documented (Task 3). ✓
- Write-back routing → `productForLinkType` helper delivered (Task 1); the actual dispatch wiring is **explicitly deferred to Plan 2** (needs runtime `dispatchToTool` integration). The `ProductModule` write-back surface exists (Task 2) so Plan 2 can implement per product.
- Setup/status/refine UX, full-union consent request, bankruptcy migration, re-homing Gmail/Calendar/Tasks → **out of scope for Plan 1** (Plans 2–4).

**2. Placeholder scan:** No "TBD"/"add error handling"/"similar to". Every code step shows complete file content or an exact edit. ✓

**3. Type consistency:** `ProductDescriptor` fields (`key`, `requiredScopes`, `scopeGroup`, `channelless`, `linkTypes`) are used identically across `composite-routing.ts`, `product-module.ts`, `composite-connector.ts`, and all tests. `parseNamespacedChannelId` returns `{ productKey, channelId }` and every caller destructures those exact names. `productStatuses`'s `state` shape (`{ locallyOff, enabledChannelCount }`) matches its test. ✓

**Deferred-to-Plan-2 hooks recorded:** write-back dispatch routing; `scopes`/`linkTypes` wiring on the concrete `GoogleConnector`; the `modules()` build-name↔key mapping for the real `tasks` collision; persisting `effectiveLinkTypes()` to `twist_instance`; exposing `productStatuses()` through the integrations API.
