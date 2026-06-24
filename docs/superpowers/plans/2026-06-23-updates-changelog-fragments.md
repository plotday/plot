# Fragment-Based Changelog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop `docs/updates.md` merge conflicts by having each PR drop a standalone changelog fragment that is folded into `docs/updates.md` (and deleted) only at release time.

**Architecture:** Each PR adds one file to `docs/updates.d/` instead of editing `docs/updates.md`. A shared module assembles fragments into a grouped `## Next release` block; three consumers reuse it — a `pnpm updates:next` preview command, the site's internal-docs sync (so `/internal/updates` shows pending + released), and the release stamp (which folds fragments into `docs/updates.md` and deletes them). `docs/updates.md` stays the permanent released history.

**Tech Stack:** Node ESM scripts (`.mjs`), `node:test` + `node:assert/strict` for unit tests, React Router site build (`apps/site`), GitHub Actions (`release.yml`).

**Spec:** `docs/superpowers/specs/2026-06-23-updates-changelog-fragments-design.md`

## Global Constraints

- Fragment directory: `docs/updates.d/` (relative to repo root).
- Fragment format: one or more `### <Section>` blocks with `- ` bullets; no `## ` (top-level) headings inside a fragment.
- Section ordering in any assembled block: feature sections in first-seen order, with the `Fixes` section (heading text exactly `Fixes`) forced **last** — matches the existing `docs/updates.md` convention.
- `docs/updates.md` is the permanent, released, append-only changelog. No `## Next release` block lives in it during a cycle (the migration in Task 7 removes the current one).
- `apps/site/app/lib/internal-docs/updates.md` is a **gitignored build artifact** — never commit it.
- Run script tests with: `node --test <path-to-test-file>` (Node's built-in runner; `import { test } from "node:test"`, `import assert from "node:assert/strict"`).
- Work on a feature branch (not `main`); commit only the files each task lists.
- `gatherFragments(dir)` returns `{ body: string, files: string[] }`; `files` are absolute paths, `body` is the grouped sections **without** the top-level heading (caller adds `## Next release` or `## <version> — <date>`).

---

### Task 1: Shared fragment-assembly module

**Files:**
- Create: `scripts/lib/updates-fragments.mjs`
- Test: `scripts/lib/updates-fragments.test.mjs`

**Interfaces:**
- Consumes: nothing (leaf module).
- Produces:
  - `parseFragment(content: string) -> Array<{ heading: string, body: string }>` — body is bullet lines joined by `\n`, leading/trailing blank lines trimmed.
  - `assembleFragments(contents: string[]) -> string` — merged, grouped sections (`### H\n\n<bullets>` joined by `\n\n`), Fixes last. `""` when no sections.
  - `gatherFragments(dir: string) -> { body: string, files: string[] }` — reads `dir/*.md` except `README.md`, filename-sorted; missing dir → `{ body: "", files: [] }`.

- [ ] **Step 1: Write the failing tests**

Create `scripts/lib/updates-fragments.test.mjs`:

```js
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { parseFragment, assembleFragments, gatherFragments } from "./updates-fragments.mjs";

test("parseFragment splits sections and trims blank lines", () => {
  const blocks = parseFragment("### Fixes\n\n- one\n- two\n\n");
  assert.deepEqual(blocks, [{ heading: "Fixes", body: "- one\n- two" }]);
});

test("parseFragment keeps wrapped continuation lines verbatim", () => {
  const blocks = parseFragment("### Threads\n\n- a long bullet\n  wrapped here\n");
  assert.deepEqual(blocks, [{ heading: "Threads", body: "- a long bullet\n  wrapped here" }]);
});

test("parseFragment handles multiple sections in one fragment", () => {
  const blocks = parseFragment("### Threads\n\n- feature\n\n### Fixes\n\n- fix\n");
  assert.deepEqual(blocks, [
    { heading: "Threads", body: "- feature" },
    { heading: "Fixes", body: "- fix" },
  ]);
});

test("assembleFragments merges identical headings and forces Fixes last", () => {
  const out = assembleFragments([
    "### Fixes\n\n- fix one\n",
    "### Threads\n\n- thread feature\n",
    "### Fixes\n\n- fix two\n",
  ]);
  assert.equal(out, "### Threads\n\n- thread feature\n\n### Fixes\n\n- fix one\n- fix two");
});

test("assembleFragments returns empty string with no input", () => {
  assert.equal(assembleFragments([]), "");
});

test("gatherFragments reads sorted .md files, excludes README.md", () => {
  const dir = mkdtempSync(join(tmpdir(), "frag-"));
  writeFileSync(join(dir, "b-second.md"), "### Fixes\n\n- second\n");
  writeFileSync(join(dir, "a-first.md"), "### Threads\n\n- first\n");
  writeFileSync(join(dir, "README.md"), "# how to add an update\n");
  const { body, files } = gatherFragments(dir);
  assert.equal(body, "### Threads\n\n- first\n\n### Fixes\n\n- second");
  assert.equal(files.length, 2);
  assert.ok(files[0].endsWith("a-first.md") && files[1].endsWith("b-second.md"));
});

test("gatherFragments on a missing dir returns empty", () => {
  const { body, files } = gatherFragments(join(tmpdir(), "does-not-exist-xyz"));
  assert.equal(body, "");
  assert.deepEqual(files, []);
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `node --test scripts/lib/updates-fragments.test.mjs`
Expected: FAIL — `Cannot find module './updates-fragments.mjs'`.

- [ ] **Step 3: Write the implementation**

Create `scripts/lib/updates-fragments.mjs`:

```js
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";

/** Parse a fragment into `{ heading, body }` blocks. Lines before the first
 *  `### ` heading are ignored. Bullet text (including wrapped continuation
 *  lines) is preserved verbatim; only blank lines around a block are trimmed. */
export function parseFragment(content) {
  const lines = content.split("\n");
  const blocks = [];
  let current = null;
  for (const line of lines) {
    const m = /^### (.+)$/.exec(line);
    if (m) {
      current = { heading: m[1].trim(), lines: [] };
      blocks.push(current);
    } else if (current) {
      current.lines.push(line);
    }
  }
  return blocks.map(({ heading, lines }) => {
    let start = 0;
    let end = lines.length;
    while (start < end && lines[start].trim() === "") start++;
    while (end > start && lines[end - 1].trim() === "") end--;
    return { heading, body: lines.slice(start, end).join("\n") };
  });
}

/** Merge fragment contents into grouped sections. Headings appear in first-seen
 *  order, except a `Fixes` section is forced last. Returns the section body
 *  WITHOUT a top-level `##` heading. */
export function assembleFragments(contents) {
  const order = [];
  const byHeading = new Map();
  for (const content of contents) {
    for (const { heading, body } of parseFragment(content)) {
      if (!byHeading.has(heading)) {
        byHeading.set(heading, []);
        order.push(heading);
      }
      byHeading.get(heading).push(body);
    }
  }
  const ordered = [
    ...order.filter((h) => h !== "Fixes"),
    ...order.filter((h) => h === "Fixes"),
  ];
  return ordered
    .map((h) => `### ${h}\n\n${byHeading.get(h).join("\n")}`)
    .join("\n\n");
}

/** Read all fragment `.md` files in `dir` (excluding README.md), filename-sorted,
 *  and assemble them. Returns the grouped body and the absolute file paths. */
export function gatherFragments(dir) {
  const abs = resolve(dir);
  if (!existsSync(abs)) return { body: "", files: [] };
  const names = readdirSync(abs)
    .filter((n) => n.endsWith(".md") && n !== "README.md")
    .sort();
  const files = names.map((n) => join(abs, n));
  const body = assembleFragments(files.map((f) => readFileSync(f, "utf8")));
  return { body, files };
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `node --test scripts/lib/updates-fragments.test.mjs`
Expected: PASS — `# pass 7  # fail 0`.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/updates-fragments.mjs scripts/lib/updates-fragments.test.mjs
git commit -m "feat(changelog): add fragment-assembly module"
```

---

### Task 2: Fold fragments into the release stamp

**Files:**
- Modify: `scripts/stamp-updates.mjs`
- Modify: `scripts/stamp-updates.test.mjs`
- Modify: `.github/workflows/release.yml:134`

**Interfaces:**
- Consumes: `gatherFragments` from Task 1.
- Produces: `stampUpdates(content, version, date, fragmentBody?) -> { stamped, content }` — when `fragmentBody` is non-empty, prepends a `## <version> — <date>` block built from it; otherwise the existing legacy behavior is unchanged.

- [ ] **Step 1: Write the failing tests**

Append to `scripts/stamp-updates.test.mjs`:

```js
test("prepends a stamped block built from fragment body, keeping prior releases", () => {
  const released = "## 1.4.0+353 — 2026-05-21\n\n### Fixes\n- shipped in 353\n";
  const fragmentBody = "### Threads\n\n- a new thread feature\n\n### Fixes\n\n- a new fix";
  const { stamped, content } = stampUpdates(released, "1.5.0+360", "2026-06-23", fragmentBody);
  assert.equal(stamped, true);
  assert.match(content, /^## 1\.5\.0\+360 — 2026-06-23\n\n### Threads\n\n- a new thread feature\n\n### Fixes\n\n- a new fix/);
  const idxNew = content.indexOf("## 1.5.0+360");
  const idxOld = content.indexOf("## 1.4.0+353");
  assert.ok(idxNew >= 0 && idxOld > idxNew, "new release precedes the prior one");
});

test("no-op when there is neither a fragment body nor a legacy unreleased block", () => {
  const released = "## 1.4.0+353 — 2026-05-21\n\n### Fixes\n- shipped in 353\n";
  const { stamped, content } = stampUpdates(released, "1.5.0+360", "2026-06-23", "");
  assert.equal(stamped, false);
  assert.equal(content, released);
});
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `node --test scripts/stamp-updates.test.mjs`
Expected: FAIL — the fragment-body test fails (4th arg ignored; current code falls into legacy path and returns `stamped:false`).

- [ ] **Step 3: Update `stampUpdates` and the CLI**

In `scripts/stamp-updates.mjs`, add the import at the top (below the existing imports):

```js
import { gatherFragments } from "./lib/updates-fragments.mjs";
```

Change the function signature and add the fragment path as the first branch inside `stampUpdates`:

```js
export function stampUpdates(content, version, date, fragmentBody = "") {
  const lines = content.split("\n");
  const heading = `## ${version} — ${date}`;

  // Preferred path: assemble pending fragments into a fresh stamped block.
  if (fragmentBody.trim()) {
    const rest = content.replace(/^\n+/, "");
    let out = `${heading}\n\n${fragmentBody.trim()}`;
    if (rest.trim().length > 0) out += `\n\n${rest}`;
    if (content.endsWith("\n") && !out.endsWith("\n")) out += "\n";
    return { stamped: true, content: out };
  }

  // Legacy path: a literal `## Next release` heading marks the cycle.
  const nextIdx = lines.findIndex((l) => l.trim() === "## Next release");
  // ...rest of the existing function body is UNCHANGED...
```

Replace the CLI block at the bottom of the file with a version that gathers and deletes fragments:

```js
// CLI: node scripts/stamp-updates.mjs <version> <date> [path=docs/updates.md] [fragdir=docs/updates.d]
if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [version, date, file = "docs/updates.md", fragDir = "docs/updates.d"] = process.argv.slice(2);
  if (!version || !date) {
    console.error("usage: node scripts/stamp-updates.mjs <version> <date> [path] [fragdir]");
    process.exit(1);
  }
  const { body, files } = gatherFragments(fragDir);
  const original = readFileSync(file, "utf8");
  const { stamped, content } = stampUpdates(original, version, date, body);
  if (!stamped) {
    console.log(`stamp-updates: no pending fragments or bullets — skipping ${version}`);
    process.exit(0);
  }
  writeFileSync(file, content);
  for (const f of files) unlinkSync(f);
  console.log(`stamp-updates: stamped ${file} for ${version} (${date}); removed ${files.length} fragment(s)`);
}
```

Update the top-of-file imports to include `unlinkSync`:

```js
import { readFileSync, writeFileSync, unlinkSync } from "node:fs";
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `node --test scripts/stamp-updates.test.mjs`
Expected: PASS — all prior tests plus the two new ones (`# fail 0`).

- [ ] **Step 5: Record fragment deletions in the release commit**

In `.github/workflows/release.yml`, change the staging line (currently line 134):

```yaml
          git add apps/plot/pubspec.yaml docs/updates.md docs/updates.d
```

- [ ] **Step 6: Commit**

```bash
git add scripts/stamp-updates.mjs scripts/stamp-updates.test.mjs .github/workflows/release.yml
git commit -m "feat(changelog): fold fragments into release stamp"
```

---

### Task 3: `pnpm updates:new` authoring helper

**Files:**
- Create: `scripts/new-update.mjs`
- Test: `scripts/new-update.test.mjs`
- Modify: `package.json` (root `scripts`)

**Interfaces:**
- Consumes: nothing.
- Produces: `slugify(text: string) -> string`, `randomId() -> string` (matches `/^[a-z0-9]{6}$/`), `fragmentTemplate() -> string`.

- [ ] **Step 1: Write the failing tests**

Create `scripts/new-update.test.mjs`:

```js
import { test } from "node:test";
import assert from "node:assert/strict";

import { slugify, randomId, fragmentTemplate } from "./new-update.mjs";

test("slugify lowercases, strips punctuation, hyphenates", () => {
  assert.equal(slugify("Email link fix!"), "email-link-fix");
  assert.equal(slugify("  Multiple   spaces  "), "multiple-spaces");
});

test("randomId is six lowercase alphanumerics", () => {
  assert.match(randomId(), /^[a-z0-9]{6}$/);
});

test("fragmentTemplate is an empty Fixes bullet", () => {
  assert.equal(fragmentTemplate(), "### Fixes\n\n- \n");
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `node --test scripts/new-update.test.mjs`
Expected: FAIL — `Cannot find module './new-update.mjs'`.

- [ ] **Step 3: Write the implementation**

Create `scripts/new-update.mjs`:

```js
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

export function slugify(text) {
  return text
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

export function randomId() {
  return Math.random().toString(36).slice(2, 8).padEnd(6, "0");
}

export function fragmentTemplate() {
  return "### Fixes\n\n- \n";
}

// CLI: node scripts/new-update.mjs "<description>" [dir=docs/updates.d]
if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const desc = process.argv[2];
  const dir = process.argv[3] || "docs/updates.d";
  if (!desc) {
    console.error('usage: node scripts/new-update.mjs "<short description>"');
    process.exit(1);
  }
  const slug = slugify(desc) || "update";
  const path = join(dir, `${slug}-${randomId()}.md`);
  mkdirSync(dir, { recursive: true });
  writeFileSync(path, fragmentTemplate());
  console.log(`Created ${path} — edit it with your update bullet(s).`);
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `node --test scripts/new-update.test.mjs`
Expected: PASS — `# pass 3  # fail 0`.

- [ ] **Step 5: Add the package.json script**

In root `package.json`, add to `scripts` (next to the other top-level scripts):

```json
    "updates:new": "node scripts/new-update.mjs",
```

- [ ] **Step 6: Commit**

```bash
git add scripts/new-update.mjs scripts/new-update.test.mjs package.json
git commit -m "feat(changelog): add pnpm updates:new helper"
```

---

### Task 4: `pnpm updates:next` preview command

**Files:**
- Create: `scripts/preview-updates.mjs`
- Modify: `package.json` (root `scripts`)

**Interfaces:**
- Consumes: `gatherFragments` from Task 1.
- Produces: a CLI only (thin wrapper over the tested `gatherFragments`); no exported API.

- [ ] **Step 1: Write the implementation**

Create `scripts/preview-updates.mjs`:

```js
import { pathToFileURL } from "node:url";

import { gatherFragments } from "./lib/updates-fragments.mjs";

// CLI: node scripts/preview-updates.mjs [dir=docs/updates.d]
if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const dir = process.argv[2] || "docs/updates.d";
  const { body } = gatherFragments(dir);
  if (!body) {
    console.log("No updates queued for the next release.");
  } else {
    console.log(`## Next release\n\n${body}`);
  }
}
```

- [ ] **Step 2: Add the package.json script**

In root `package.json`, add to `scripts`:

```json
    "updates:next": "node scripts/preview-updates.mjs",
```

- [ ] **Step 3: Verify manually**

```bash
mkdir -p docs/updates.d
node scripts/new-update.mjs "Preview smoke test"
# edit the created file's bullet to "- preview smoke test", then:
pnpm updates:next
```

Expected: prints a `## Next release` block containing your bullet under `### Fixes`. Then delete the smoke-test fragment file so it isn't committed:

```bash
rm docs/updates.d/preview-smoke-test-*.md
```

- [ ] **Step 4: Commit**

```bash
git add scripts/preview-updates.mjs package.json
git commit -m "feat(changelog): add pnpm updates:next preview"
```

---

### Task 5: Fragment validation in lint

**Files:**
- Create: `scripts/check-updates-fragments.mjs`
- Test: `scripts/check-updates-fragments.test.mjs`
- Modify: `package.json` (root `scripts`: add `updates:check`, chain into `lint`)

**Interfaces:**
- Consumes: nothing.
- Produces: `validateFragment(content: string) -> string[]` — empty array when valid; otherwise human-readable error strings.

- [ ] **Step 1: Write the failing tests**

Create `scripts/check-updates-fragments.test.mjs`:

```js
import { test } from "node:test";
import assert from "node:assert/strict";

import { validateFragment } from "./check-updates-fragments.mjs";

test("valid fragment has no errors", () => {
  assert.deepEqual(validateFragment("### Fixes\n\n- a real fix\n"), []);
});

test("flags a missing ### heading", () => {
  const errors = validateFragment("- a bullet with no section\n");
  assert.ok(errors.some((e) => /### section heading/.test(e)));
});

test("flags a missing bullet", () => {
  const errors = validateFragment("### Fixes\n\n");
  assert.ok(errors.some((e) => /- bullet/.test(e)));
});

test("flags a stray ## top-level heading", () => {
  const errors = validateFragment("## Next release\n\n### Fixes\n\n- x\n");
  assert.ok(errors.some((e) => /## top-level heading/.test(e)));
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `node --test scripts/check-updates-fragments.test.mjs`
Expected: FAIL — `Cannot find module './check-updates-fragments.mjs'`.

- [ ] **Step 3: Write the implementation**

Create `scripts/check-updates-fragments.mjs`:

```js
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

export function validateFragment(content) {
  const errors = [];
  if (!/^### .+/m.test(content)) errors.push("missing a ### section heading");
  if (!/^- /m.test(content)) errors.push("missing a - bullet");
  if (/^## /m.test(content)) errors.push("contains a ## top-level heading (use ### sections only)");
  return errors;
}

// CLI: node scripts/check-updates-fragments.mjs [dir=docs/updates.d]
if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const dir = process.argv[2] || "docs/updates.d";
  if (!existsSync(dir)) {
    console.log("check-updates-fragments: no docs/updates.d directory — nothing to check.");
    process.exit(0);
  }
  const names = readdirSync(dir).filter((n) => n.endsWith(".md") && n !== "README.md");
  let failed = false;
  for (const name of names) {
    const errors = validateFragment(readFileSync(join(dir, name), "utf8"));
    if (errors.length) {
      failed = true;
      console.error(`✗ ${name}:`);
      for (const e of errors) console.error(`    - ${e}`);
    }
  }
  if (failed) {
    console.error("check-updates-fragments: invalid fragment(s) found.");
    process.exit(1);
  }
  console.log(`check-updates-fragments: ${names.length} fragment(s) OK.`);
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `node --test scripts/check-updates-fragments.test.mjs`
Expected: PASS — `# pass 4  # fail 0`.

- [ ] **Step 5: Wire into lint**

In root `package.json`, add the script and chain it into `lint` after `lint:store-metadata`:

```json
    "lint": "pnpm lint:pnpm-installed && pnpm lint:store-metadata && pnpm updates:check && nx run-many -t lint --exclude plot",
    "updates:check": "node scripts/check-updates-fragments.mjs",
```

- [ ] **Step 6: Verify the lint wiring runs**

Run: `pnpm updates:check`
Expected: `check-updates-fragments: 0 fragment(s) OK.` (no `docs/updates.d` content yet) or a count, exit 0.

- [ ] **Step 7: Commit**

```bash
git add scripts/check-updates-fragments.mjs scripts/check-updates-fragments.test.mjs package.json
git commit -m "feat(changelog): validate fragments in lint"
```

---

### Task 6: Render pending fragments on the internal docs page

**Files:**
- Modify: `apps/site/scripts/sync-internal-docs.mjs`

**Interfaces:**
- Consumes: `gatherFragments` from Task 1 (imported by relative path across the repo; this script is run directly by node, not bundled).
- Produces: writes a combined `updates.md` (pending block prepended to released history) into `apps/site/app/lib/internal-docs/` — a gitignored artifact.

- [ ] **Step 1: Update the sync script**

Replace `apps/site/scripts/sync-internal-docs.mjs` with:

```js
import { mkdirSync, copyFileSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { gatherFragments } from "../../../scripts/lib/updates-fragments.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repoDocs = resolve(here, "../../../docs");
const fragDir = resolve(here, "../../../docs/updates.d");
const outDir = resolve(here, "../app/lib/internal-docs");

mkdirSync(outDir, { recursive: true });
for (const file of ["features.md", "updates.md", "voice.md", "store-listings.md"]) {
  if (file === "updates.md") {
    const released = readFileSync(resolve(repoDocs, file), "utf8");
    const { body } = gatherFragments(fragDir);
    const combined = body ? `## Next release\n\n${body}\n\n${released}` : released;
    writeFileSync(resolve(outDir, file), combined);
    console.log(`sync-internal-docs: assembled ${file}${body ? " (with pending fragments)" : ""}`);
  } else {
    copyFileSync(resolve(repoDocs, file), resolve(outDir, file));
    console.log(`sync-internal-docs: copied ${file}`);
  }
}
```

- [ ] **Step 2: Verify manually**

```bash
node scripts/new-update.mjs "Internal page smoke test"
# edit the bullet to "- internal page smoke test"
node apps/site/scripts/sync-internal-docs.mjs
head -8 apps/site/app/lib/internal-docs/updates.md
```

Expected: the generated file starts with `## Next release`, then `### Fixes`, then your bullet, then the released history below. Clean up the smoke fragment:

```bash
rm docs/updates.d/internal-page-smoke-test-*.md
node apps/site/scripts/sync-internal-docs.mjs   # regenerate without the smoke fragment
```

- [ ] **Step 3: Commit**

```bash
git add apps/site/scripts/sync-internal-docs.mjs
git commit -m "feat(changelog): show pending fragments on internal updates page"
```

---

### Task 7: Migrate current pending bullets + document the workflow

**Files:**
- Create: `docs/updates.d/README.md`
- Create: `docs/updates.d/migrate-pending-<id>.md` (use a real id, e.g. from `node scripts/new-update.mjs`)
- Modify: `docs/updates.md` (remove the `## Next release` block)
- Modify: `AGENTS.md` (the two `docs/updates.md` authoring bullets)
- Modify: `.agents/skills/finalize/SKILL.md` (the `docs/updates.md` bullet)

**Interfaces:**
- Consumes: everything from Tasks 1–6.
- Produces: a clean repo state where `docs/updates.md` holds only released history and the current pending bullets live as a fragment.

- [ ] **Step 1: Add the directory README**

Create `docs/updates.d/README.md`:

```markdown
# Changelog fragments

Each user-facing change adds **one file here** instead of editing
`../updates.md`. Because every PR touches a different file, changelog edits
never conflict.

## Add an update

```bash
pnpm updates:new "short description"
```

Then edit the created file. A fragment is one or more `### <Section>` blocks with
bullets — exactly what you'd write in `updates.md`:

```md
### Fixes

- Plain-language description of the change a user would notice.
```

- Use a descriptive feature section (e.g. `### Threads`) for features; put bug
  fixes under `### Fixes` (always rendered last).
- One fragment may contain several sections if a PR spans a feature and a fix.
- Skip internal refactors / infra / changes users wouldn't notice.

## What happens next

- `pnpm updates:next` prints everything queued for the next release.
- The internal docs page (`/internal/updates`) shows queued fragments above the
  released history.
- At release, the fragments are folded into `../updates.md` under the new version
  heading and deleted automatically.
```

- [ ] **Step 2: Move the current pending bullets into a fragment**

Read the current `## Next release` block at the top of `docs/updates.md` (its `### Fixes` bullets). Create `docs/updates.d/migrate-pending-<id>.md` containing exactly that `### Fixes` heading and those bullets (verbatim). Then remove the entire `## Next release` section (heading through the blank line before the first `## <version>` heading) from `docs/updates.md`, so the file now begins with the most recent stamped release.

- [ ] **Step 3: Verify the migration round-trips**

```bash
pnpm updates:check                 # fragment is valid
pnpm updates:next                  # prints the migrated bullets under ## Next release
node apps/site/scripts/sync-internal-docs.mjs
head -12 apps/site/app/lib/internal-docs/updates.md   # pending block on top, then released history
```

Expected: the migrated Fixes bullets appear in the preview and at the top of the generated internal page; `docs/updates.md` itself starts with the latest `## <version>` heading.

- [ ] **Step 4: Update AGENTS.md guidance**

In `AGENTS.md`, update the two changelog references:
- The `/finalize` Documentation step (~line 498): change "Notable user-facing changes go in `docs/updates.md`" to "Notable user-facing changes add a fragment in `docs/updates.d/` (via `pnpm updates:new`)."
- The "When completing user-facing changes" block (~line 629): replace "add a brief bullet point to `docs/updates.md`" with "run `pnpm updates:new \"…\"` (or hand-write `docs/updates.d/<slug>-<id>.md`) and add a brief bullet". Keep the existing section-naming and Fixes-last structure rules, but reframe them as the fragment's `### Section` blocks; note that fragments are folded into `docs/updates.md` automatically at release.

- [ ] **Step 5: Update the finalize skill**

In `.agents/skills/finalize/SKILL.md` (~line 51), change "Add a bullet point to the top of `docs/updates.md`" to "Add a fragment via `pnpm updates:new` (one file in `docs/updates.d/`, folded into `docs/updates.md` at release)."

- [ ] **Step 6: Run the full check + commit**

```bash
pnpm updates:check
node --test scripts/lib/updates-fragments.test.mjs scripts/stamp-updates.test.mjs scripts/new-update.test.mjs scripts/check-updates-fragments.test.mjs
git add docs/updates.d docs/updates.md AGENTS.md .agents/skills/finalize/SKILL.md
git commit -m "feat(changelog): migrate pending bullets to fragments + document workflow"
```

Expected: `updates:check` OK; all `node --test` suites pass (`# fail 0`).

---

## Self-Review

**Spec coverage:**
- Fragment dir & format → Task 1 (parsing), Task 7 (README + migration). ✓
- `gatherFragments` shared module → Task 1. ✓
- Preview command → Task 4. ✓
- Internal docs page wiring → Task 6. ✓
- Release stamp fold + delete → Task 2 (incl. `release.yml git add`). ✓
- Authoring helper → Task 3. ✓
- CI validation → Task 5. ✓
- One-time migration → Task 7. ✓
- Guidance updates (AGENTS.md, finalize) → Task 7. ✓
- Tests (gather + stamp) → Tasks 1, 2 (plus helper/validation tests in 3, 5). ✓

**Placeholder scan:** `<id>` in Task 7 filename is an instruction to generate a real id (Step 2 of Task 7 spells this out), not a literal to commit. No TBD/TODO/"handle edge cases" steps remain.

**Type consistency:** `gatherFragments(dir) -> { body, files }`, `assembleFragments(string[]) -> string`, `parseFragment(string) -> {heading, body}[]`, `stampUpdates(content, version, date, fragmentBody?)`, `validateFragment(string) -> string[]`, `slugify`/`randomId`/`fragmentTemplate` — names and signatures are used identically across Tasks 1–7. ✓
