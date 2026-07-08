# Newsletter Email Formatting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make newsletter/digest emails render as one tidy note by adding three deterministic transforms to the shared server-side HTML→Markdown path.

**Architecture:** All work is in one file — `workers/api/src/twist/tools/plot/thread-helpers.ts` — extending the two existing pure functions `preprocessEmailHtml` (HTMLRewriter, pre-AI) and `cleanConvertedMarkdown` (post-AI). Every mail connector (Gmail, Outlook, future) flows through this chokepoint via `convertNoteToMarkdown`, so one change fixes them all. Both target functions are already unit-tested directly, so the entire change is deterministic and needs no AI binding to test.

**Tech Stack:** TypeScript, Cloudflare `HTMLRewriter`, Vitest (`@cloudflare/vitest-pool-workers`).

## Global Constraints

- Server-only change: **no** connector edits, **no** `public/` submodule changes, **no** changeset, **no** DB/schema/migration.
- **Deterministic only** — no AI, no network fetches, no per-email newsletter gating. Transforms must be safe on ordinary (non-newsletter) email.
- **Footer stays** — do not trim Unsubscribe / Manage Preferences / Privacy / Help Center or the copyright/address block.
- Tests live in `workers/api/src/twist/tools/__tests__/email-html.test.ts` and run under `vitest.integration.config.ts` (the default `vitest.config.ts` **excludes** `__tests__/`).
- All commit messages end with the trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- Baseline before any change: `email-html.test.ts` = **36 passing**.
- All commands run from `workers/api/` inside the worktree `.claude/worktrees/newsletter-email-formatting/`.

**Spec:** `docs/superpowers/specs/2026-07-07-newsletter-email-formatting-design.md`

---

### Task 1: Drop empty-recipient `mailto:` share buttons

Newsletter articles carry a `mailto:?subject=Shared%20Via…` "Share" button per story. An empty-recipient mailto is always a compose/share widget, never "email this person", so it is safe to drop while keeping real `mailto:someone@example.com` links.

**Files:**
- Modify: `workers/api/src/twist/tools/plot/thread-helpers.ts` (function `preprocessEmailHtml`, currently `:553`–`:580`)
- Test: `workers/api/src/twist/tools/__tests__/email-html.test.ts` (the `describe("preprocessEmailHtml", …)` block)

**Interfaces:**
- Consumes: existing `preprocessEmailHtml(html: string): Promise<string>`.
- Produces: same signature; adds an `a`-element handler to the rewriter. Task 2 further extends this same function.

- [ ] **Step 1: Write the failing tests**

Add inside the existing `describe("preprocessEmailHtml", () => { … })` block in `email-html.test.ts`:

```ts
  it("drops empty-recipient mailto: share buttons", async () => {
    const html = `<p>Story headline</p>
      <a href="mailto:?subject=Shared%20Via%20Firefox&body=Check%20this%20out">Share</a>`;
    const out = await preprocessEmailHtml(html);
    expect(out).not.toMatch(/mailto:\?/i);
    expect(out).not.toContain("Share");
    expect(out).toContain("Story headline");
  });

  it("preserves real mailto: links to a specific address", async () => {
    const html = `<p>Contact <a href="mailto:kris@example.com">Kris</a> directly.</p>`;
    const out = await preprocessEmailHtml(html);
    expect(out).toContain("mailto:kris@example.com");
    expect(out).toContain("Kris");
  });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd workers/api && pnpm exec vitest run --config vitest.integration.config.ts src/twist/tools/__tests__/email-html.test.ts -t "mailto"`
Expected: FAIL — "drops empty-recipient mailto: share buttons" fails because the `mailto:?` anchor and its "Share" text survive. ("preserves real mailto" passes already.)

- [ ] **Step 3: Add the `a`-element handler**

In `thread-helpers.ts`, inside `preprocessEmailHtml`, add a handler to the `rewriter` chain (place it right after `.on("head", remove)`). The full chain currently reads `.onDocument(...).on("style", remove).on("script", remove).on("head", remove).on("table", unwrap)...`. Insert:

```ts
    .on("a", {
      element: (el: Element) => {
        // Empty-recipient mailto (`mailto:` or `mailto:?…`) is a compose/share
        // widget ("Share via…"), never "email this person" — drop it and its
        // text. A real `mailto:someone@example.com` link is preserved.
        const href = (el.getAttribute("href") ?? "").trim();
        if (/^mailto:(\?|$)/i.test(href)) {
          el.remove();
        }
      },
    })
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd workers/api && pnpm exec vitest run --config vitest.integration.config.ts src/twist/tools/__tests__/email-html.test.ts -t "mailto"`
Expected: PASS (both).

- [ ] **Step 5: Commit**

```bash
git add workers/api/src/twist/tools/plot/thread-helpers.ts workers/api/src/twist/tools/__tests__/email-html.test.ts
git commit -m "$(cat <<'EOF'
feat(api): drop empty-recipient mailto share buttons from email notes

Newsletter/digest emails attach a `mailto:?subject=Shared via…` Share
button to every article. Empty-recipient mailto is always a share/compose
widget, so preprocessEmailHtml now removes it while preserving real
mailto:address links.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Drop hidden preheader/teaser content and tracking pixels

Newsletters hide a preheader teaser (e.g. "Plus: …") in a `display:none` container and embed a 1×1 tracking pixel. Hidden = the recipient's mail client never showed it, so removal matches what the user saw.

**Files:**
- Modify: `workers/api/src/twist/tools/plot/thread-helpers.ts` (function `preprocessEmailHtml`, as edited by Task 1)
- Test: `workers/api/src/twist/tools/__tests__/email-html.test.ts` (the `describe("preprocessEmailHtml", …)` block)

**Interfaces:**
- Consumes: `preprocessEmailHtml` (Task 1 version).
- Produces: adds a module-private `isHiddenStyle(el: Element): boolean` helper and new element handlers; folds a hidden-check into the existing `unwrap`/`toDiv` handlers.

- [ ] **Step 1: Write the failing tests**

Add inside the `describe("preprocessEmailHtml", …)` block:

```ts
  it("drops hidden preheader/teaser containers", async () => {
    const html = `
      <div style="display:none !important;visibility:hidden;opacity:0;max-height:0;">Plus: the hidden teaser</div>
      <span style="visibility:hidden">invisible span</span>
      <p style="opacity:0">transparent para</p>
      <p style="opacity:0.9">faint but visible</p>
      <p>Visible body.</p>`;
    const out = await preprocessEmailHtml(html);
    expect(out).not.toContain("hidden teaser");
    expect(out).not.toContain("invisible span");
    expect(out).not.toContain("transparent para");
    expect(out).toContain("faint but visible");
    expect(out).toContain("Visible body.");
  });

  it("drops 1x1 tracking-pixel images but keeps normal images", async () => {
    const html = `<p>Body</p>
      <img src="https://track.example/pixel.gif" width="1" height="1" alt="" />
      <img src="https://cdn.example/photo.jpg" width="600" height="400" alt="Photo" />`;
    const out = await preprocessEmailHtml(html);
    expect(out).not.toContain("track.example/pixel.gif");
    expect(out).toContain("cdn.example/photo.jpg");
    expect(out).toContain("Body");
  });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd workers/api && pnpm exec vitest run --config vitest.integration.config.ts src/twist/tools/__tests__/email-html.test.ts -t "hidden preheader|tracking-pixel"`
Expected: FAIL — hidden containers and the 1×1 pixel currently survive.

- [ ] **Step 3: Add the `isHiddenStyle` helper**

In `thread-helpers.ts`, add this function immediately **before** `export async function preprocessEmailHtml`:

```ts
/**
 * True when an element's inline `style` marks it visually hidden: `display:none`,
 * `visibility:hidden`, or fully transparent (`opacity:0`). Email newsletters use
 * these for preheader teasers and tracking-pixel wrappers — content the recipient
 * never saw. `opacity:0` must not match `opacity:0.9`, so the `0` may not be
 * followed by a dot or digit.
 */
function isHiddenStyle(el: Element): boolean {
  const style = (el.getAttribute("style") ?? "")
    .replace(/\s+/g, "")
    .toLowerCase();
  if (!style) return false;
  return (
    style.includes("display:none") ||
    style.includes("visibility:hidden") ||
    /opacity:0(?![.\d])/.test(style)
  );
}
```

- [ ] **Step 4: Wire the hidden-check into `preprocessEmailHtml`**

In `preprocessEmailHtml`, change the existing `unwrap` and `toDiv` handler consts to remove hidden elements before transforming, and add `removeIfHidden` plus new handlers. Replace the current:

```ts
  const remove = { element: (el: Element) => { el.remove(); } };
  const unwrap = { element: (el: Element) => { el.removeAndKeepContent(); } };
  const toDiv = { element: (el: Element) => { el.tagName = "div"; } };
```

with:

```ts
  const remove = { element: (el: Element) => { el.remove(); } };
  const removeIfHidden = {
    element: (el: Element) => { if (isHiddenStyle(el)) el.remove(); },
  };
  const unwrap = {
    element: (el: Element) => {
      if (isHiddenStyle(el)) { el.remove(); return; }
      el.removeAndKeepContent();
    },
  };
  const toDiv = {
    element: (el: Element) => {
      if (isHiddenStyle(el)) { el.remove(); return; }
      el.tagName = "div";
    },
  };
  const dropImg = {
    element: (el: Element) => {
      if (isHiddenStyle(el)) { el.remove(); return; }
      // 1×1 (or smaller) images are tracking pixels, not content.
      const w = parseInt(el.getAttribute("width") ?? "", 10);
      const h = parseInt(el.getAttribute("height") ?? "", 10);
      if ((w > 0 && w <= 1) || (h > 0 && h <= 1)) el.remove();
    },
  };
```

Then, in the `.on(...)` chain, add these handlers (place after the existing `.on("th", toDiv)`):

```ts
    .on("div", removeIfHidden)
    .on("span", removeIfHidden)
    .on("p", removeIfHidden)
    .on("img", dropImg)
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd workers/api && pnpm exec vitest run --config vitest.integration.config.ts src/twist/tools/__tests__/email-html.test.ts -t "hidden preheader|tracking-pixel"`
Expected: PASS (both).

- [ ] **Step 6: Run the whole preprocessEmailHtml block to check for regressions**

Run: `cd workers/api && pnpm exec vitest run --config vitest.integration.config.ts src/twist/tools/__tests__/email-html.test.ts -t "preprocessEmailHtml"`
Expected: PASS (all preprocessEmailHtml tests, including the pre-existing ones).

- [ ] **Step 7: Commit**

```bash
git add workers/api/src/twist/tools/plot/thread-helpers.ts workers/api/src/twist/tools/__tests__/email-html.test.ts
git commit -m "$(cat <<'EOF'
feat(api): drop hidden preheader teasers and tracking pixels from email notes

preprocessEmailHtml now removes elements marked display:none /
visibility:hidden / opacity:0 (newsletter preheader teasers and
tracking-pixel wrappers) and standalone <=1x1 pixel images, while keeping
normal images and faint-but-visible (opacity:0.x) content.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: De-duplicate links to the same href

Digest layouts link the poster image, headline, and dek all to the same story URL, so each story renders its link 2–3×. Keep only the first link of a contiguous same-href run; de-link the rest to plain text. A same-href link separated by prose (or a different link) starts a new run and stays a link, so a genuine repeated CTA is preserved.

**Files:**
- Modify: `workers/api/src/twist/tools/plot/thread-helpers.ts` (function `cleanConvertedMarkdown`, `:379`; new helper before it)
- Test: `workers/api/src/twist/tools/__tests__/email-html.test.ts` (new `describe` block)

**Interfaces:**
- Consumes: existing `cleanConvertedMarkdown(markdown: string): string`.
- Produces: adds module-private `dedupeAdjacentSameHrefLinks(markdown: string): string`, invoked inside `cleanConvertedMarkdown` after the inline-link normalization and before the line-splitting loop.

- [ ] **Step 1: Write the failing tests**

Add a new `describe` block to `email-html.test.ts` (e.g. after the `describe("cleanConvertedMarkdown — glued inline elements", …)` block):

```ts
describe("cleanConvertedMarkdown — duplicate same-href links", () => {
  it("keeps the first link and de-links a contiguous same-href repeat", () => {
    // Digest layout: headline and dek both link to the same story URL.
    const input = [
      "[What we learned from the exit](https://ex.com/story)",
      "",
      "[This generation may still turn out golden.](https://ex.com/story)",
    ].join("\n");
    const out = cleanConvertedMarkdown(input);
    expect(out).toBe(
      "[What we learned from the exit](https://ex.com/story)\n\nThis generation may still turn out golden."
    );
  });

  it("collapses a run of three same-href links to one", () => {
    const input = [
      "[Headline](https://ex.com/a)",
      "",
      "[Dek](https://ex.com/a)",
      "",
      "[Read more](https://ex.com/a)",
    ].join("\n");
    const out = cleanConvertedMarkdown(input);
    expect(out).toBe("[Headline](https://ex.com/a)\n\nDek\n\nRead more");
  });

  it("keeps links to different hrefs", () => {
    const input = "[Story A](https://ex.com/a)\n\n[Story B](https://ex.com/b)";
    const out = cleanConvertedMarkdown(input);
    expect(out).toBe(input);
  });

  it("keeps a same-href link that recurs after intervening prose", () => {
    const input = [
      "[Sign up](https://ex.com/join)",
      "",
      "We would love to have you at the event next week.",
      "",
      "[Sign up](https://ex.com/join)",
    ].join("\n");
    const out = cleanConvertedMarkdown(input);
    expect(out).toBe(input);
  });

  it("does not treat an inline image-link as a duplicate link", () => {
    // Inline image-links survive cleanup; the dedupe must ignore them so it
    // neither de-links them nor mis-reads their inner href.
    const input =
      "Read ![icon](https://cdn.example/i.png) then [Story](https://ex.com/a).";
    const out = cleanConvertedMarkdown(input);
    expect(out).toBe(input);
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd workers/api && pnpm exec vitest run --config vitest.integration.config.ts src/twist/tools/__tests__/email-html.test.ts -t "duplicate same-href"`
Expected: FAIL — "keeps the first link and de-links…" and "collapses a run of three…" fail (repeats still linked). The three negative tests pass already.

- [ ] **Step 3: Add the `dedupeAdjacentSameHrefLinks` helper**

In `thread-helpers.ts`, add this function immediately **before** `export function cleanConvertedMarkdown`:

```ts
/**
 * Collapse duplicate links to the same href. Newsletter/digest layouts link the
 * poster image, headline, and dek all to one story URL, so each story renders its
 * link 2–3×. Keep the FIRST link of a run of same-href links that are contiguous
 * (separated only by whitespace) and de-link the rest to their plain text. A
 * same-href link separated from the previous one by other content (prose, a
 * different link) starts a new run and stays a link — so a genuinely repeated CTA
 * later in the note is preserved. Inline image-links (`![alt](src)`) are ignored.
 */
function dedupeAdjacentSameHrefLinks(markdown: string): string {
  // Inline links only. `(?<!!)` excludes image syntax `![alt](src)`; the href
  // capture runs up to whitespace or the closing paren.
  const linkRe = /(?<!!)\[([^\]]+)\]\(([^)\s]+)\)/g;
  type Hit = { start: number; end: number; text: string; href: string };
  const hits: Hit[] = [];
  let m: RegExpExecArray | null;
  while ((m = linkRe.exec(markdown)) !== null) {
    // Skip image-links like `[ ![alt](src) ](url)` — leave them untouched.
    if (m[1].includes("![")) continue;
    hits.push({ start: m.index, end: linkRe.lastIndex, text: m[1], href: m[2] });
  }

  const lastEndByHref = new Map<string, number>();
  const delink: Hit[] = [];
  for (const hit of hits) {
    const prevEnd = lastEndByHref.get(hit.href);
    if (prevEnd !== undefined && markdown.slice(prevEnd, hit.start).trim() === "") {
      // Contiguous repeat of the same href → de-link this one.
      delink.push(hit);
    }
    // Advance the marker whether kept or de-linked so a run of 3+ collapses.
    lastEndByHref.set(hit.href, hit.end);
  }

  // Apply de-link replacements right-to-left so offsets stay valid.
  for (let i = delink.length - 1; i >= 0; i--) {
    const hit = delink[i];
    markdown = markdown.slice(0, hit.start) + hit.text + markdown.slice(hit.end);
  }
  return markdown;
}
```

- [ ] **Step 4: Call the helper from `cleanConvertedMarkdown`**

In `cleanConvertedMarkdown`, insert the call just **after** the glued-inline-element restoration block (the three chained `.replace(...)` ending with the `([A-Za-z0-9])\*\*(?=[A-Za-z0-9[])` rule, currently `:447`–`:454`) and **before** `const lines = markdown.split("\n");` (`:456`):

```ts
  // Collapse duplicate links to the same href (digest layouts link the poster
  // image, headline, and dek all to one story URL).
  markdown = dedupeAdjacentSameHrefLinks(markdown);
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd workers/api && pnpm exec vitest run --config vitest.integration.config.ts src/twist/tools/__tests__/email-html.test.ts -t "duplicate same-href"`
Expected: PASS (all five).

- [ ] **Step 6: Commit**

```bash
git add workers/api/src/twist/tools/plot/thread-helpers.ts workers/api/src/twist/tools/__tests__/email-html.test.ts
git commit -m "$(cat <<'EOF'
feat(api): de-duplicate same-href links in email notes

Newsletter/digest layouts link the poster image, headline, and dek all to
one story URL, rendering the link 2-3x per story. cleanConvertedMarkdown
now keeps the first link of a contiguous same-href run and de-links the
rest to plain text; prose-separated repeats and different-href links are
left intact.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Full suite green, lint, and user-facing update note

**Files:**
- Create: `workers/api/` lint is clean; add a docs updates fragment via the repo helper.
- Verify: `workers/api/src/twist/tools/__tests__/email-html.test.ts` all pass.

**Interfaces:** none (finalization task).

- [ ] **Step 1: Run the full email-html suite**

Run: `cd workers/api && pnpm exec vitest run --config vitest.integration.config.ts src/twist/tools/__tests__/email-html.test.ts`
Expected: PASS — 36 baseline + the new tests (Task 1: 2, Task 2: 2, Task 3: 5) = **45 passing**.

- [ ] **Step 2: Lint the package**

Run: `cd workers/api && pnpm lint`
Expected: no errors. (Fix any lint errors introduced by the new code before proceeding.)

- [ ] **Step 3: Add a user-facing update fragment**

From the repo root, run: `pnpm updates:new "Newsletter emails are tidier"`
Then edit the generated file under `docs/updates.d/` so it contains a single `### Fixes` section with this bullet (replace any placeholder body):

```markdown
### Fixes

- Newsletter and digest emails now come through cleaner — duplicate story links, "Share" buttons, hidden preview text, and tracking pixels are stripped so you see just the headlines and summaries.
```

- [ ] **Step 4: Commit**

```bash
git add docs/updates.d
git commit -m "$(cat <<'EOF'
docs: add update note for tidier newsletter emails

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 5: Optional end-to-end eyeball (manual, needs AI binding)**

If you want to see the full pipeline output on the real Ten Tabs HTML, run the API worker locally (`pnpm --filter @plotday/api dev`) and feed the HTML through `convertNoteToMarkdown`. Not required for correctness — the deterministic transforms are fully covered by the unit tests above. Note: this requires the Cloudflare Workers AI binding, so it is a manual eyeball, not an automated gate.

---

## Notes for the implementer

- The default `vitest.config.ts` **excludes** `src/**/__tests__/**`, so always pass `--config vitest.integration.config.ts` when running `email-html.test.ts`. Running plain `pnpm test` will report "No test files found" for this file — that is expected, not a failure.
- If the worktree's Twister SDK dist is missing (`Cannot find package '@plotday/twister/utils/markdown'`), build it once: `cd public/twister && pnpm build`.
- `HTMLRewriter`, JS regex lookbehind (`(?<!…)`), and `Element`/`Comment` types are all already used in this file — no new imports needed.
- After all tasks, run `/finalize` before opening the PR (lint, backwards-compat, error-capture, docs — this plan already covers lint and the docs fragment).
