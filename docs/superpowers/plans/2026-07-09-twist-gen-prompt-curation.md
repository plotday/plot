# Twist Generation Prompt Curation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Trim Connector/imap/smtp docs out of the twist-generation prompt and add three complete, compilable exemplar twists, via a public twister change plus core generator wiring.

**Architecture:** The twister package gains `src/exemplars/*.ts` (real twists compiled by the package build — rot-proof), a prebuild step that embeds them as a formatted `TWIST_EXEMPLARS` string (same mechanism as the twist-guide template), and `getTwistDocumentation()` (builder docs minus connector/imap/smtp). The core generator switches to the twist-scoped docs and appends the exemplars section; prompt stays static per version so provider caching is preserved.

**Tech Stack:** twister package (tsx prebuild, tsc build, changesets), vitest (core), eval harness.

**Spec:** `docs/superpowers/specs/2026-07-09-twist-gen-prompt-curation-design.md` — read before starting.

## Global Constraints

- Two repos: public submodule work on branch `twist-prompt-curation` in `public/` (create off the CURRENT submodule HEAD `bc27482`, which matches origin/main); core work on branch `twist-gen-prompt-curation` in the worktree `/Users/kris.braun/code/plot/.claude/worktrees/twist-gen-eval-harness`.
- **The `public/` repo is world-readable**: its commit messages and code comments are for an external audience — describe SDK behavior, never core-repo internals, eval-harness references, PR numbers, or measurement data.
- Excluded from `getTwistDocumentation()`: exactly `@plotday/twister/connector`, `@plotday/twister/tools/imap`, `@plotday/twister/tools/smtp`. `getBuilderDocumentation()` unchanged.
- Exemplars: complete idiomatic twists, 40–80 lines each, default-export class extending `Twist<Self>`, headed by a `/* SPEC: ... */` block comment in user language; domains must NOT mirror the eval corpus specs.
- Prebuild fails loudly on a missing/spec-less exemplar (no silent empty examples section).
- Changeset required (minor, `Added:` prefix); validate with `cd public && pnpm validate-changesets`.
- Core prompt structure (instructions/messages/caching/retry conversation) untouched beyond the docs-content swap and appended examples section.
- Live-run spend authorized: Pro comparison (~$6) + flash comparison (~$1), executed by the controller session.
- Lint gates: twister `pnpm build` clean; core `pnpm --filter @plotday/api lint` 0 errors, no new warnings.
- Core commit messages end with: `Co-Authored-By: Claude <noreply@anthropic.com>`. Public commits too (same trailer).

---

### Task 1: Twister — exemplars, prebuild embed, getTwistDocumentation, changeset (public submodule)

**Files (all under `public/`):**
- Create: `twister/src/exemplars/ai-responder.ts`, `twister/src/exemplars/authenticated-sync.ts`, `twister/src/exemplars/scheduled-digest.ts`
- Modify: `twister/prebuild.ts` (embed step), `twister/src/creator-docs.ts` (new exports)
- Create: `.changeset/twist-prompt-docs.md`

**Interfaces:**
- Consumes: existing prebuild patterns (`twist-guide-template.ts` embed), package exports map with the `@plotday/connector` custom condition (self-referencing `@plotday/twister` imports resolve to `./src/*` inside the package — the same way workspace twists import it).
- Produces (Task 2 imports from `@plotday/twister/creator-docs`): `getTwistDocumentation(): string`; `TWIST_EXEMPLARS: string` (contains `## Example: AI Responder`, `## Example: Authenticated Sync`, `## Example: Scheduled Digest`).

- [ ] **Step 1: Create the public branch**

```bash
cd public && git switch -c twist-prompt-curation && git log --oneline -1 && cd ..
```

- [ ] **Step 2: Write the three exemplars**

The drafts below are the canonical INTENT (structure, tool wiring, comment style). They must COMPILE against the real SDK: where a field/method name or option shape differs, correct the draft to the SDK — consulting `public/twister/docs/TOOLS_GUIDE.md`, `public/twister/docs/MULTI_USER_AUTH.md`, `public/twister/docs/SYNC_STRATEGIES.md`, `public/twister/cli/templates/AGENTS.template.md`, and the type definitions in `public/twister/src/` — WITHOUT changing which pattern each exemplar teaches. Keep the `/* SPEC: ... */` header format exactly (the prebuild parser depends on it). List every correction in your report.

`twister/src/exemplars/ai-responder.ts`:

```typescript
/* SPEC:
When someone writes a journal note in another language, reply in the same
thread with a short plain-English summary of what they wrote, so they can
check their own understanding. Don't react to notes written by automations.
*/
import { ActorType, Twist, type Note, type ToolBuilder } from "@plotday/twister";
import { AI } from "@plotday/twister/tools/ai";
import { Plot } from "@plotday/twister/tools/plot";

export default class LanguageJournal extends Twist<LanguageJournal> {
  build(build: ToolBuilder) {
    return {
      plot: build(Plot),
      ai: build(AI),
    };
  }

  // Fires for every new note visible to this twist. Guard against notes
  // from twists/automations so we never loop on our own replies.
  async onNoteCreated(note: Note): Promise<void> {
    if (note.author?.type === ActorType.Twist) {
      return;
    }
    if (!note.content || note.content.trim().length === 0) {
      return;
    }

    const response = await this.tools.ai.prompt({
      prompt: `Summarize this journal entry in one or two plain-English sentences:\n\n${note.content}`,
    });
    if (!response.text) {
      return;
    }

    // Reply in the same thread the note belongs to.
    await this.tools.plot.createNote({
      thread: { id: note.thread.id },
      content: `English summary: ${response.text}`,
    });
  }
}
```

`twister/src/exemplars/authenticated-sync.ts`:

```typescript
/* SPEC:
Connect to my bookmarking service account. Once connected, import my starred
bookmarks as threads (title + link note), and check for new ones every hour.
Imported bookmarks must not duplicate on re-sync.
*/
import { Twist, type ToolBuilder } from "@plotday/twister";
import { Integrations } from "@plotday/twister/tools/integrations";
import { Plot } from "@plotday/twister/tools/plot";

const CHANNEL_ID = "starred-bookmarks";

export default class BookmarkSync extends Twist<BookmarkSync> {
  build(build: ToolBuilder) {
    return {
      plot: build(Plot),
      // Integrations manages OAuth tokens: request scopes here, then fetch
      // a live token with integrations.get() whenever syncing.
      integrations: build(Integrations),
    };
  }

  async activate() {
    // Re-runs hourly under a stable key; survives restarts and upgrades.
    await this.scheduleRecurring(
      "hourly-sync",
      await this.callback(this.sync),
      { intervalMs: 60 * 60 * 1000 }
    );
    await this.sync();
  }

  async sync(): Promise<void> {
    // Tokens are never cached by the twist — always fetched fresh.
    const auth = await this.tools.integrations.get(CHANNEL_ID);
    if (!auth) {
      return; // Not connected yet; nothing to sync.
    }

    const response = await fetch("https://api.bookmarks.example/v1/starred", {
      headers: { Authorization: `Bearer ${auth.accessToken}` },
    });
    if (!response.ok) {
      return;
    }
    const { bookmarks } = (await response.json()) as {
      bookmarks: Array<{ id: string; title: string; url: string }>;
    };

    // source + key give automatic upserts: re-syncing the same bookmark
    // updates the existing thread instead of creating a duplicate.
    for (const bookmark of bookmarks) {
      await this.tools.integrations.saveLink({
        source: "bookmarks.example",
        key: bookmark.id,
        channelId: CHANNEL_ID,
        title: bookmark.title,
        url: bookmark.url,
        notes: [{ content: bookmark.url }],
      });
    }
  }
}
```

`twister/src/exemplars/scheduled-digest.ts`:

```typescript
/* SPEC:
Every morning, post a thread with today's weather forecast for my city so I
can plan the day. One thread per day, titled with the date.
*/
import { Twist, type ToolBuilder } from "@plotday/twister";
import { Plot } from "@plotday/twister/tools/plot";

export default class WeatherDigest extends Twist<WeatherDigest> {
  build(build: ToolBuilder) {
    return {
      plot: build(Plot),
    };
  }

  async activate() {
    await this.scheduleRecurring(
      "morning-digest",
      await this.callback(this.postDigest),
      { intervalMs: 24 * 60 * 60 * 1000 }
    );
  }

  async postDigest(): Promise<void> {
    const response = await fetch(
      "https://api.open-meteo.com/v1/forecast?latitude=43.65&longitude=-79.38&daily=temperature_2m_max,precipitation_probability_mean&timezone=auto&forecast_days=1"
    );
    if (!response.ok) {
      return;
    }
    const data = (await response.json()) as {
      daily: {
        temperature_2m_max: number[];
        precipitation_probability_mean: number[];
      };
    };

    const today = new Date().toISOString().slice(0, 10);
    await this.tools.plot.createThread({
      title: `Weather for ${today}`,
      notes: [
        {
          content: `High of ${data.daily.temperature_2m_max[0]}°C, ${data.daily.precipitation_probability_mean[0]}% chance of rain.`,
        },
      ],
    });
  }
}
```

- [ ] **Step 3: Prebuild embed**

In `twister/prebuild.ts`, after the twist-guide-template generation block, add:

```ts
// Generate twist-exemplars.ts from src/exemplars/*.ts — complete example
// twists embedded for LLM generation prompts. Each file must start with a
// /* SPEC: ... */ block comment (the user-style specification it implements).
const exemplarsDir = join(srcDir, "exemplars");
if (!existsSync(exemplarsDir)) {
  throw new Error("prebuild: src/exemplars/ is missing");
}
const exemplarFiles = readdirSync(exemplarsDir)
  .filter((f) => f.endsWith(".ts"))
  .sort();
if (exemplarFiles.length === 0) {
  throw new Error("prebuild: src/exemplars/ contains no exemplars");
}
const exemplarSections = exemplarFiles.map((file) => {
  const raw = readFileSync(join(exemplarsDir, file), "utf-8");
  const specMatch = raw.match(/^\/\*\s*SPEC:\s*\n([\s\S]*?)\*\/\s*\n/);
  if (!specMatch) {
    throw new Error(`prebuild: ${file} is missing its leading /* SPEC: */ comment`);
  }
  const spec = specMatch[1].trim();
  const implementation = raw.slice(specMatch[0].length).trim();
  const title = file
    .replace(/\.ts$/, "")
    .split("-")
    .map((w) => w[0].toUpperCase() + w.slice(1))
    .join(" ");
  return `## Example: ${title}\n\n### Specification\n\n${spec}\n\n### Implementation\n\n\`\`\`typescript\n${implementation}\n\`\`\``;
});
const exemplarsContent = `/**
 * Generated example twists for LLM generation prompts.
 *
 * This file is auto-generated during build. Do not edit manually.
 * Generated from: src/exemplars/*.ts
 */

export default ${JSON.stringify(exemplarSections.join("\n\n"))};
`;
writeFileSync(join(llmDocsDir, "twist-exemplars.ts"), exemplarsContent, "utf-8");
console.log(`✓ Generated twist-exemplars.ts from ${exemplarFiles.length} exemplars`);
```

Add `readdirSync` to the existing `fs` import if missing. IMPORTANT: `llmDocsDir` is cleaned and recreated at the top of prebuild — the exemplars generation must come AFTER that (it does, being at the end) — and the exemplar SOURCE files live outside `llm-docs`, so they survive the clean.

- [ ] **Step 4: creator-docs exports**

In `twister/src/creator-docs.ts` add (matching the file's existing import style):

```ts
import twistExemplars from "./llm-docs/twist-exemplars.js";

// Modules excluded from TWIST generation docs: twists must never extend
// Connector, and the mail-protocol tools are niche enough to dilute the
// prompt more than they help.
const TWIST_DOC_EXCLUSIONS = new Set([
  "@plotday/twister/connector",
  "@plotday/twister/tools/imap",
  "@plotday/twister/tools/smtp",
]);

/**
 * Twist-scoped variant of getBuilderDocumentation(): the same formatted
 * type definitions, minus modules that are irrelevant (or misleading) when
 * generating a twist.
 */
export function getTwistDocumentation(): string {
  let documentation = "# Plot Twist Creator Type Definitions\n\n";
  documentation +=
    "Complete type definitions with JSDoc documentation for all Plot Twist Creator types.\n";
  documentation +=
    "These are the source files - use the import paths shown to import types in your twist code.\n\n";
  for (const [importPath, content] of Object.entries(llmDocs)) {
    if (TWIST_DOC_EXCLUSIONS.has(importPath)) continue;
    documentation += `## ${importPath}\n\n`;
    documentation += "```typescript\n";
    documentation += `// Import from: ${importPath}\n\n`;
    documentation += content;
    documentation += "\n```\n\n";
  }
  return documentation;
}

/**
 * Complete example twists (specification + implementation pairs) for LLM
 * generation prompts. The examples are real compiled sources in
 * src/exemplars/, so they are type-checked on every build.
 */
export const TWIST_EXEMPLARS: string = twistExemplars;
```

(If the file's existing generated-import style omits the `.js` extension, match it.)

- [ ] **Step 5: Build + verify**

```bash
cd public/twister && pnpm build && node -e "
const d = require('./dist/creator-docs.js');
const twist = d.getTwistDocumentation();
const builder = d.getBuilderDocumentation();
if (twist.includes('@plotday/twister/connector')) throw new Error('connector not excluded');
if (twist.includes('tools/imap') || twist.includes('tools/smtp')) throw new Error('mail tools not excluded');
if (!builder.includes('@plotday/twister/connector')) throw new Error('builder docs must keep connector');
for (const t of ['AI Responder','Authenticated Sync','Scheduled Digest']) {
  if (!d.TWIST_EXEMPLARS.includes('## Example: ' + t)) throw new Error('missing exemplar ' + t);
}
console.log('OK — twist docs', twist.length, 'chars; builder', builder.length, 'chars; exemplars', d.TWIST_EXEMPLARS.length, 'chars');
" && cd ../..
```

Expected: build succeeds (the exemplars type-check as part of `src/**/*.ts` — self-referencing `@plotday/twister` imports resolve through the package's exports custom condition; if tsc rejects the self-reference, STOP and report NEEDS_CONTEXT with the exact error rather than restructuring imports), and the node assertions print OK with twist docs materially smaller than builder docs.

- [ ] **Step 6: Changeset + validate**

Create `public/.changeset/twist-prompt-docs.md`:

```markdown
---
"@plotday/twister": minor
---

Added: getTwistDocumentation() (twist-scoped LLM documentation that omits connector-only modules) and TWIST_EXEMPLARS (complete example twists, compiled and type-checked on every build) for generation prompts.
```

Run: `cd public && pnpm validate-changesets && cd ..` — passes.

- [ ] **Step 7: Commit (public repo — external audience)**

```bash
cd public && git add twister/src/exemplars twister/prebuild.ts twister/src/creator-docs.ts .changeset/twist-prompt-docs.md && git commit -m "feat(twister): twist-scoped LLM docs and compiled example twists

getTwistDocumentation() provides the generation-prompt documentation set
without connector-only modules (twists never extend Connector), and
TWIST_EXEMPLARS embeds three complete example twists — AI responder,
authenticated sync, scheduled digest — whose sources compile with the
package, so examples can never drift from the SDK.

Co-Authored-By: Claude <noreply@anthropic.com>" && git log --oneline -1 && cd ..
```

---

### Task 2: Core — generator wiring + gitlink bump

**Files:**
- Modify: `workers/api/src/twist/generator.ts`
- Test: `workers/api/src/twist/generator.test.ts`
- Modify: gitlink `public` (staged submodule pointer)

**Interfaces:**
- Consumes: `getTwistDocumentation`, `TWIST_EXEMPLARS` from `@plotday/twister/creator-docs` (Task 1, via workspace link — Task 1's build refreshed `public/twister/dist`).

- [ ] **Step 1: Update tests first**

In `workers/api/src/twist/generator.test.ts`, replace the creator-docs mock with:

```ts
vi.mock("@plotday/twister/creator-docs", () => ({
  getBuilderDocumentation: () => "<BUILDER_DOCS>",
  getTwistDocumentation: () => "<TWIST_DOCS>",
  TWIST_EXEMPLARS: "<EXEMPLARS>",
}));
```

Update the two prompt-content assertions (gemini default test asserts on the string `call.instructions`; claude test on `call.instructions.content`): replace the `<SDK_DOCS>` expectations with `<TWIST_DOCS>`, keep `<TWIST_GUIDE>`, and ADD `expect(...).toContain("<EXEMPLARS>")` plus `expect(...).not.toContain("<BUILDER_DOCS>")` to both.

- [ ] **Step 2: Run to verify failures**

Run from workers/api: `npx vitest run src/twist/generator.test.ts`
Expected: the two prompt tests FAIL (prompt still built from getBuilderDocumentation).

- [ ] **Step 3: Implement**

In `workers/api/src/twist/generator.ts`:
- Import change: `import { getTwistDocumentation, TWIST_EXEMPLARS } from "@plotday/twister/creator-docs";` (drop the getBuilderDocumentation import).
- `const sdkDocs = getTwistDocumentation();` (rename comment references accordingly).
- System prompt becomes:

```ts
    const systemPrompt = `You are an expert at generating Plot twists.

${sdkDocs}

${TWIST_GUIDE}

# Complete examples

${TWIST_EXEMPLARS}`;
```

- [ ] **Step 4: Verify**

Run: `npx vitest run src/twist/generator.test.ts` — ALL pass. `pnpm --filter @plotday/api lint` — 0 errors, no new warnings.

- [ ] **Step 5: Commit core (with gitlink)**

```bash
git add public workers/api/src/twist/generator.ts workers/api/src/twist/generator.test.ts
git commit -m "feat(api): twist prompt uses twist-scoped docs + embedded exemplars

The generation prompt now uses getTwistDocumentation() (drops the
Connector base class and mail-protocol tools, ~12K tokens of content a
twist must never or rarely use) and appends three complete compiled
exemplar twists targeting the tool-wiring patterns type docs alone don't
teach. Bumps the public submodule to the twist-prompt-curation branch tip.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: Measurement runs (CONTROLLER-EXECUTED)

No implementer subagent — controller runs from its own session background. Prereqs: Docker up, `.dev.vars`, twister dist built (Task 1 did).

- [ ] **Step 1: Pro comparison (~$6)**

`pnpm --filter @plotday/api eval:twist-gen --label pr-c --runs 2 --compare evals/results/20260709-021506-pr-b.json`
Gates: full-pass ≥ 75% − noise (>8pp drop = stop), pipeline 100%. Target: assertion_failed < 6, especially ai-intents/auth-integration; per-call input tokens visibly lower.

- [ ] **Step 2: Flash comparison (~$1)**

`pnpm --filter @plotday/api eval:twist-gen --model gemini-3-flash-preview --label pr-c-flash --runs 2`
Compare against `20260709-022136-pr-b-flash.json` (71%). Gate: ≥ 71% − noise; target improvement.

- [ ] **Step 3: Record**

Append both scorecards + verdicts to `.superpowers/sdd/progress.md`.

---

## Final verification (after all tasks)

1. Twister build green (exemplars compiled); changeset validates; core tests + lint green.
2. Both measurement runs recorded with honest gate evaluation.
3. Public PR opened from `twist-prompt-curation` (external-audience body); core PR references it; gitlink re-pointed after the public PR merges.
