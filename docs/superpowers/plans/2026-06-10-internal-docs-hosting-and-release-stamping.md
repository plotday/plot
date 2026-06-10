# Internal Docs Hosting + Release-Stamped Changelog — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Host `docs/features.md` and `docs/updates.md` privately on the marketing site behind `@plot.day` Clerk sign-in, and auto-stamp `docs/updates.md` with the release version on every native release.

**Architecture:** Part B (changelog stamping) is a pure Node script wired into `release.yml`'s `prepare-release` job — build it first, it's independently testable. Part A (hosted docs) adds server-gated routes to `apps/site`: the markdown is copied into a gitignored, server-only module at build time and rendered **only from loaders** that call a `requireTeamMember` gate, so content never enters the public client bundle.

**Tech Stack:** Node ESM + `node:test` (stamp script + tests); React Router v7 framework mode on Cloudflare Workers, Clerk (`@clerk/react-router`), Mantine, `marked` (new dep), Vite `?raw` imports.

---

## File Structure

**Part B — changelog stamping (repo root):**
- Create `scripts/stamp-updates.mjs` — pure `stampUpdates(content, version, date)` + CLI that reads/writes `docs/updates.md`.
- Create `scripts/stamp-updates.test.mjs` — `node:test` unit tests.
- Modify `.github/workflows/release.yml` — stamp step in `prepare-release`.
- Modify `AGENTS.md` — update the `docs/updates.md` hint.

**Part A — hosted docs (`apps/site`):**
- Create `apps/site/scripts/sync-internal-docs.mjs` — copies repo docs into the package at build/dev time.
- Create `apps/site/app/types/raw-md.d.ts` — `*.md?raw` module type.
- Create `apps/site/app/lib/internal-docs.server.ts` — `?raw` imports + `marked` render.
- Create `apps/site/app/lib/internal-auth.server.ts` — `requireTeamMember` gate.
- Create `apps/site/app/components/internal-layout.tsx` — minimal internal chrome.
- Create `apps/site/app/routes/internal._index.tsx`, `internal.features.tsx`, `internal.updates.tsx`.
- Modify `apps/site/app/routes.ts` — register the internal layout + routes.
- Modify `apps/site/package.json` — add `marked`, prepend sync to `build`/`dev`.
- Modify `apps/site/.gitignore` — ignore the synced docs dir.

---

## Task 1: Changelog stamping logic (`stampUpdates`)

**Files:**
- Create: `scripts/stamp-updates.mjs`
- Test: `scripts/stamp-updates.test.mjs`

- [ ] **Step 1: Write the failing tests**

Create `scripts/stamp-updates.test.mjs`:

```js
import { test } from "node:test";
import assert from "node:assert/strict";

import { stampUpdates } from "./stamp-updates.mjs";

test("stamps unreleased bullets above the first legacy --- separator", () => {
  const input = ["- new thing one", "- new thing two", "", "---", "", "- old published thing", ""].join("\n");
  const { stamped, content } = stampUpdates(input, "1.1.0+296", "2026-06-10");
  assert.equal(stamped, true);
  assert.match(content, /^## 1\.1\.0\+296 — 2026-06-10\n\n- new thing one\n- new thing two/);
  // legacy history is preserved untouched, below the new section
  assert.match(content, /---\n\n- old published thing/);
});

test("inserts above a prior ## version heading, preserving it", () => {
  const input = ["- fresh bullet", "", "## 1.1.0+295 — 2026-06-03", "", "- shipped in 295", ""].join("\n");
  const { stamped, content } = stampUpdates(input, "1.1.0+296", "2026-06-10");
  assert.equal(stamped, true);
  const idx296 = content.indexOf("## 1.1.0+296");
  const idx295 = content.indexOf("## 1.1.0+295");
  assert.ok(idx296 >= 0 && idx295 > idx296, "new heading precedes the old one");
  assert.match(content, /## 1\.1\.0\+296 — 2026-06-10\n\n- fresh bullet/);
});

test("skips when the unreleased block has no bullets", () => {
  const input = ["## 1.1.0+295 — 2026-06-03", "", "- shipped in 295", ""].join("\n");
  const { stamped, content } = stampUpdates(input, "1.1.0+296", "2026-06-10");
  assert.equal(stamped, false);
  assert.equal(content, input);
});

test("stamps the whole file when there is no heading or separator", () => {
  const input = ["- only bullet", ""].join("\n");
  const { stamped, content } = stampUpdates(input, "1.1.0+296", "2026-06-10");
  assert.equal(stamped, true);
  assert.match(content, /^## 1\.1\.0\+296 — 2026-06-10\n\n- only bullet/);
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `node --test scripts/stamp-updates.test.mjs`
Expected: FAIL — `Cannot find module './stamp-updates.mjs'` / `stampUpdates is not a function`.

- [ ] **Step 3: Implement the script**

Create `scripts/stamp-updates.mjs`:

```js
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";

/**
 * Insert a `## <version> — <date>` heading above the unreleased bullets at the
 * top of an updates.md changelog. The unreleased block is everything above the
 * first `## ` version heading, or (if none) above the first `---` separator, or
 * (if neither) the whole file. Returns `{ stamped, content }`; `stamped` is
 * false (and content unchanged) when the unreleased block has no `- ` bullet.
 */
export function stampUpdates(content, version, date) {
  const lines = content.split("\n");

  let boundary = lines.length;
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].startsWith("## ")) {
      boundary = i;
      break;
    }
    if (lines[i].trim() === "---" && boundary === lines.length) {
      boundary = i;
    }
  }

  const unreleased = lines.slice(0, boundary).join("\n").trim();
  const rest = lines.slice(boundary).join("\n").replace(/^\n+/, "");

  if (!/^- /m.test(unreleased)) {
    return { stamped: false, content };
  }

  const heading = `## ${version} — ${date}`;
  let out = `${heading}\n\n${unreleased}`;
  if (rest.trim().length > 0) {
    out += `\n\n${rest}`;
  }
  if (content.endsWith("\n")) {
    out += "\n";
  }
  return { stamped: true, content: out };
}

// CLI: node scripts/stamp-updates.mjs <version> <date> [path=docs/updates.md]
if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [version, date, file = "docs/updates.md"] = process.argv.slice(2);
  if (!version || !date) {
    console.error("usage: node scripts/stamp-updates.mjs <version> <date> [path]");
    process.exit(1);
  }
  const original = readFileSync(file, "utf8");
  const { stamped, content } = stampUpdates(original, version, date);
  if (!stamped) {
    console.log(`stamp-updates: no unreleased bullets — skipping ${version}`);
    process.exit(0);
  }
  writeFileSync(file, content);
  console.log(`stamp-updates: stamped ${file} for ${version} (${date})`);
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `node --test scripts/stamp-updates.test.mjs`
Expected: PASS — 4 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add scripts/stamp-updates.mjs scripts/stamp-updates.test.mjs
git commit -m "feat(release): add updates.md changelog stamping script"
```

---

## Task 2: Wire stamping into `release.yml`

**Files:**
- Modify: `.github/workflows/release.yml` (the `prepare-release` job's "Bump main to next build number" step, ~lines 90-105)

- [ ] **Step 1: Replace the bump step with a stamp+bump step**

Find this step:

```yaml
      - name: Bump main to next build number
        run: |
          git checkout main

          cd apps/plot
          NEXT_BUILD_NUMBER=$((${{ steps.version.outputs.build_number }} + 1))
          NEXT_VERSION="${{ steps.version.outputs.version_name }}+${NEXT_BUILD_NUMBER}"
          sed -i "s/version: .*/version: ${NEXT_VERSION}/" pubspec.yaml

          git config user.name '${{ steps.app-token.outputs.app-slug }}[bot]'
          git config user.email '${{ steps.app-user.outputs.user-id }}+${{ steps.app-token.outputs.app-slug }}[bot]@users.noreply.github.com'
          git add pubspec.yaml
          git commit -m "Bump version to ${NEXT_VERSION} [skip ci]"
          git push

          echo "Bumped main to: $NEXT_VERSION"
```

Replace it with:

```yaml
      - name: Stamp changelog and bump main to next build number
        run: |
          git checkout main

          RELEASE_VERSION="${{ steps.version.outputs.release_version }}"
          STAMP_DATE="$(date -u +%Y-%m-%d)"
          node scripts/stamp-updates.mjs "$RELEASE_VERSION" "$STAMP_DATE"

          cd apps/plot
          NEXT_BUILD_NUMBER=$((${{ steps.version.outputs.build_number }} + 1))
          NEXT_VERSION="${{ steps.version.outputs.version_name }}+${NEXT_BUILD_NUMBER}"
          sed -i "s/version: .*/version: ${NEXT_VERSION}/" pubspec.yaml
          cd ..

          git config user.name '${{ steps.app-token.outputs.app-slug }}[bot]'
          git config user.email '${{ steps.app-user.outputs.user-id }}+${{ steps.app-token.outputs.app-slug }}[bot]@users.noreply.github.com'
          git add apps/plot/pubspec.yaml docs/updates.md
          git commit -m "Release ${RELEASE_VERSION}: stamp changelog + bump to ${NEXT_VERSION} [skip ci]"
          git push

          echo "Stamped changelog for $RELEASE_VERSION; bumped main to: $NEXT_VERSION"
```

Note: `node scripts/stamp-updates.mjs` runs from the repo root (each `run:` block starts at the workspace root). It edits `docs/updates.md`; if there are no unreleased bullets it leaves the file unchanged, and `git add docs/updates.md` simply stages nothing for it — the commit still succeeds via the pubspec change.

- [ ] **Step 2: Validate the workflow YAML**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/release.yml')); print('valid yaml')"`
Expected: `valid yaml`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "feat(release): stamp updates.md with release version on native release"
```

---

## Task 3: Update the `AGENTS.md` changelog hint

**Files:**
- Modify: `AGENTS.md` (the "Hints" bullet about `docs/updates.md`)

- [ ] **Step 1: Replace the final sentence of the updates.md hint**

Find (the last sentence of the `When completing user-facing changes` bullet):

```
When the user publishes an update, add `---` below the current section to archive it and start fresh above.
```

Replace with:

```
Add new bullets at the very top of the file, above the first `## <version> — <date>` heading — that top block is the "unreleased" set. You no longer add `---` separators by hand: the `Release` workflow (`release.yml`) auto-inserts a `## <version> — <date>` heading above the unreleased bullets on every native release (`scripts/stamp-updates.mjs`). The older `---`-delimited blocks at the bottom of the file are historical and left as-is.
```

- [ ] **Step 2: Verify the edit landed**

Run: `grep -n "scripts/stamp-updates.mjs" AGENTS.md`
Expected: one line match inside the hint.

- [ ] **Step 3: Commit**

```bash
git add AGENTS.md
git commit -m "docs: describe auto-stamped updates.md changelog flow"
```

---

## Task 4: Site build-time doc sync + `marked` dependency

**Files:**
- Create: `apps/site/scripts/sync-internal-docs.mjs`
- Create: `apps/site/app/types/raw-md.d.ts`
- Modify: `apps/site/.gitignore`
- Modify: `apps/site/package.json`

- [ ] **Step 1: Create the sync script**

Create `apps/site/scripts/sync-internal-docs.mjs`:

```js
import { mkdirSync, copyFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repoDocs = resolve(here, "../../../docs");
const outDir = resolve(here, "../app/lib/internal-docs");

mkdirSync(outDir, { recursive: true });
for (const file of ["features.md", "updates.md"]) {
  copyFileSync(resolve(repoDocs, file), resolve(outDir, file));
  console.log(`sync-internal-docs: copied ${file}`);
}
```

- [ ] **Step 2: Create the `?raw` module type**

Create `apps/site/app/types/raw-md.d.ts`:

```ts
declare module "*.md?raw" {
  const content: string;
  export default content;
}
```

- [ ] **Step 3: Ignore the synced dir**

Add to `apps/site/.gitignore` (append a new line):

```
/app/lib/internal-docs/
```

- [ ] **Step 4: Add `marked` and wire the sync into build/dev**

Run: `pnpm --filter @plotday/site add marked`

Then edit `apps/site/package.json` `scripts` — change `build` and `dev`:

```json
    "build": "node scripts/sync-internal-docs.mjs && react-router build",
    "dev": "node scripts/sync-internal-docs.mjs && react-router dev",
```

- [ ] **Step 5: Run the sync and verify the files appear**

Run: `cd apps/site && node scripts/sync-internal-docs.mjs && ls app/lib/internal-docs/`
Expected: prints two "copied" lines and lists `features.md` and `updates.md`.

- [ ] **Step 6: Commit**

```bash
git add apps/site/scripts/sync-internal-docs.mjs apps/site/app/types/raw-md.d.ts apps/site/.gitignore apps/site/package.json pnpm-lock.yaml
git commit -m "feat(site): sync internal docs into build + add marked"
```

---

## Task 5: Server-only doc render + auth gate

**Files:**
- Create: `apps/site/app/lib/internal-docs.server.ts`
- Create: `apps/site/app/lib/internal-auth.server.ts`

- [ ] **Step 1: Create the render module**

Create `apps/site/app/lib/internal-docs.server.ts`:

```ts
import { marked } from "marked";

import featuresMd from "./internal-docs/features.md?raw";
import updatesMd from "./internal-docs/updates.md?raw";

export function renderFeatures(): string {
  return marked.parse(featuresMd, { async: false });
}

export function renderUpdates(): string {
  return marked.parse(updatesMd, { async: false });
}
```

- [ ] **Step 2: Create the team-member gate**

Create `apps/site/app/lib/internal-auth.server.ts`:

```ts
import { redirect } from "react-router";
import type { LoaderFunctionArgs } from "react-router";

import { getAuth } from "@clerk/react-router/ssr.server";
import { createClerkClient } from "@clerk/react-router/api.server";

import { initClerkEnv } from "./clerk.server";

const ALLOWED_DOMAIN = "@plot.day";

/**
 * Server-only gate for the /internal docs. Throws a redirect to /signin when
 * the request is unauthenticated, and a 403 Response when the signed-in user is
 * not on the @plot.day domain. Returns the verified email on success.
 *
 * Call this FIRST in every internal loader, before reading any doc content, so
 * unauthenticated/forbidden requests never receive doc bytes.
 */
export async function requireTeamMember(
  args: LoaderFunctionArgs,
): Promise<{ email: string }> {
  const env = args.context.cloudflare.env as Record<string, string>;
  initClerkEnv(env);

  const auth = await getAuth(args);
  if (!auth.userId) {
    const pathname = new URL(args.request.url).pathname;
    throw redirect(`/signin?returnTo=${encodeURIComponent(pathname)}`);
  }

  const client = createClerkClient({
    secretKey: env.CLERK_SECRET_KEY,
    publishableKey: env.CLERK_PUBLISHABLE_KEY,
  });
  const user = await client.users.getUser(auth.userId);
  const email = user.primaryEmailAddress?.emailAddress ?? "";

  if (!email.toLowerCase().endsWith(ALLOWED_DOMAIN)) {
    throw new Response("Forbidden", { status: 403 });
  }

  return { email };
}
```

- [ ] **Step 3: Typecheck both modules**

Run: `cd apps/site && pnpm exec react-router typegen && pnpm exec tsc --noEmit`
Expected: no errors referencing `internal-docs.server.ts` or `internal-auth.server.ts`. (If `tsc` reports unrelated pre-existing errors, note them but confirm the new files are clean.)

- [ ] **Step 4: Commit**

```bash
git add apps/site/app/lib/internal-docs.server.ts apps/site/app/lib/internal-auth.server.ts
git commit -m "feat(site): server-only internal-docs render + @plot.day auth gate"
```

---

## Task 6: Internal layout + routes

**Files:**
- Create: `apps/site/app/components/internal-layout.tsx`
- Create: `apps/site/app/routes/internal._index.tsx`
- Create: `apps/site/app/routes/internal.features.tsx`
- Create: `apps/site/app/routes/internal.updates.tsx`
- Modify: `apps/site/app/routes.ts`

- [ ] **Step 1: Create the minimal internal layout**

Create `apps/site/app/components/internal-layout.tsx`:

```tsx
import { AppShell, Anchor, Group } from "@mantine/core";
import { Link, Outlet } from "react-router";

export default function InternalLayout() {
  return (
    <AppShell header={{ height: 56 }}>
      <AppShell.Header p="xs">
        <Group justify="space-between" h="100%" px="sm">
          <Group gap="lg">
            <Anchor component={Link} to="/internal" fw={600}>
              Plot Internal
            </Anchor>
            <Anchor component={Link} to="/internal/features">
              Features
            </Anchor>
            <Anchor component={Link} to="/internal/updates">
              Updates
            </Anchor>
          </Group>
          <Anchor component={Link} to="/signout">
            Sign out
          </Anchor>
        </Group>
      </AppShell.Header>
      <AppShell.Main>
        <Outlet />
      </AppShell.Main>
    </AppShell>
  );
}
```

- [ ] **Step 2: Create the index route**

Create `apps/site/app/routes/internal._index.tsx`:

```tsx
import { Anchor, Container, Stack, Text, Title } from "@mantine/core";
import { Link } from "react-router";

import type { Route } from "./+types/internal._index";
import { requireTeamMember } from "../lib/internal-auth.server";

export function meta(_: Route.MetaArgs) {
  return [
    { title: "Internal Docs | Plot" },
    { name: "robots", content: "noindex" },
  ];
}

export async function loader(args: Route.LoaderArgs) {
  const { email } = await requireTeamMember(args);
  return { email };
}

export default function InternalIndex({ loaderData }: Route.ComponentProps) {
  return (
    <Container mt="xl" size="sm">
      <Stack gap="md">
        <Title order={1}>Plot internal docs</Title>
        <Text c="dimmed">Signed in as {loaderData.email}</Text>
        <Anchor component={Link} to="/internal/features">
          Product features (marketing source catalog)
        </Anchor>
        <Anchor component={Link} to="/internal/updates">
          Updates / changelog by release
        </Anchor>
      </Stack>
    </Container>
  );
}
```

- [ ] **Step 3: Create the features route**

Create `apps/site/app/routes/internal.features.tsx`:

```tsx
import { Container, TypographyStylesProvider } from "@mantine/core";

import type { Route } from "./+types/internal.features";
import { requireTeamMember } from "../lib/internal-auth.server";
import { renderFeatures } from "../lib/internal-docs.server";

export function meta(_: Route.MetaArgs) {
  return [
    { title: "Features | Plot Internal" },
    { name: "robots", content: "noindex" },
  ];
}

export async function loader(args: Route.LoaderArgs) {
  await requireTeamMember(args);
  return { html: renderFeatures() };
}

export default function InternalFeatures({ loaderData }: Route.ComponentProps) {
  return (
    <Container mt="lg" size="md">
      <TypographyStylesProvider>
        <div dangerouslySetInnerHTML={{ __html: loaderData.html }} />
      </TypographyStylesProvider>
    </Container>
  );
}
```

- [ ] **Step 4: Create the updates route**

Create `apps/site/app/routes/internal.updates.tsx`:

```tsx
import { Container, TypographyStylesProvider } from "@mantine/core";

import type { Route } from "./+types/internal.updates";
import { requireTeamMember } from "../lib/internal-auth.server";
import { renderUpdates } from "../lib/internal-docs.server";

export function meta(_: Route.MetaArgs) {
  return [
    { title: "Updates | Plot Internal" },
    { name: "robots", content: "noindex" },
  ];
}

export async function loader(args: Route.LoaderArgs) {
  await requireTeamMember(args);
  return { html: renderUpdates() };
}

export default function InternalUpdates({ loaderData }: Route.ComponentProps) {
  return (
    <Container mt="lg" size="md">
      <TypographyStylesProvider>
        <div dangerouslySetInnerHTML={{ __html: loaderData.html }} />
      </TypographyStylesProvider>
    </Container>
  );
}
```

- [ ] **Step 5: Register the routes**

Edit `apps/site/app/routes.ts`. The file currently ends:

```ts
    route("twister/login", "routes/twister.login.tsx"),
  ]),
] satisfies RouteConfig;
```

Add a sibling `layout(...)` block immediately after the closing `]),` of the public layout (i.e. before `] satisfies RouteConfig;`):

```ts
    route("twister/login", "routes/twister.login.tsx"),
  ]),
  layout("./components/internal-layout.tsx", [
    route("internal", "routes/internal._index.tsx"),
    route("internal/features", "routes/internal.features.tsx"),
    route("internal/updates", "routes/internal.updates.tsx"),
  ]),
] satisfies RouteConfig;
```

`layout`, `route`, and `RouteConfig` are already imported at the top of the file — no import change needed.

- [ ] **Step 6: Typecheck the routes**

Run: `cd apps/site && pnpm exec react-router typegen && pnpm exec tsc --noEmit`
Expected: no errors in the new `internal.*` route files or `internal-layout.tsx`.

- [ ] **Step 7: Commit**

```bash
git add apps/site/app/components/internal-layout.tsx apps/site/app/routes/internal._index.tsx apps/site/app/routes/internal.features.tsx apps/site/app/routes/internal.updates.tsx apps/site/app/routes.ts
git commit -m "feat(site): add gated /internal docs routes"
```

---

## Task 7: Full verification (lint, build, server-gate smoke test)

**Files:** none (verification only)

- [ ] **Step 1: Lint the site**

Run: `pnpm --filter @plotday/site lint`
Expected: passes (`tsc && eslint`). Fix any errors introduced by the new files before continuing.

- [ ] **Step 2: Production build succeeds and bundles the docs server-side**

Run: `pnpm --filter @plotday/site build`
Expected: build completes. Then verify the doc content is NOT in the client bundle:

Run: `grep -rl "Internal catalog of product features" apps/site/build/client 2>/dev/null || echo "NOT IN CLIENT BUNDLE (good)"`
Expected: `NOT IN CLIENT BUNDLE (good)` — the `features.md` first-line marker must not appear in any client asset. (If it prints a file path, the content leaked into the client bundle — stop and fix: ensure the `?raw` import lives only in `internal-docs.server.ts` and is reached only from loaders.)

- [ ] **Step 3: Unauthenticated request is redirected with no content**

Start the dev server: `pnpm --filter @plotday/site dev` (note the printed localhost URL/port, e.g. `http://localhost:5173`).

In another shell, run (substitute the actual port):
`curl -si "http://localhost:5173/internal/features" | head -n 20`
Expected: a `30x` redirect whose `location` header points at `/signin?returnTo=%2Finternal%2Ffeatures` (or a Clerk handshake redirect), and **no** features markdown in the body. Stop the dev server when done.

- [ ] **Step 4: Final confirmation**

Confirm all of: Task 1 tests pass (`node --test scripts/stamp-updates.test.mjs`), site lint passes, build passes, the client-bundle grep prints the "good" message, and the unauthenticated curl redirects. Only then is the feature complete.

---

## Self-Review notes (for the executor)

- **No unit-test harness exists in `apps/site`** (its `lint` is `tsc && eslint`; there is no vitest). Part A is therefore verified by typecheck + build + the client-bundle grep + the unauthenticated-curl smoke test in Task 7, rather than by component unit tests. Part B's pure logic IS unit-tested via `node:test` in Task 1.
- **Clerk env vars** (`CLERK_SECRET_KEY`, `CLERK_PUBLISHABLE_KEY`) are assumed present on `context.cloudflare.env` (Clerk already powers `/signin` and `twister.login.tsx`). If `tsc` complains they're missing from the env type, read them via the existing `Record<string, string>` cast already used in `root.tsx:40`.
- **Editing docs during `dev`** won't hot-reload the internal pages (the sync copies once at dev start); re-run `dev` to pick up doc edits. This is acceptable for an internal tool.
