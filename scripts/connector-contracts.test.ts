import { readdirSync, readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

/**
 * Repo-level regression guard: a connector whose `onChannelEnabled` never
 * signals initial-sync completion leaves the connection stuck in the
 * "syncing…" state from the platform's point of view, and the stuck-sync
 * watchdog eventually force-flags an otherwise-healthy connection as needing
 * reconnection. Slack shipped with exactly this bug (fixed by having
 * `onChannelEnabled`'s batch chain call
 * `this.tools.integrations.channelSyncCompleted(channelId)` on its terminal
 * batch). Since the contract
 * ("Call `integrations.channelSyncCompleted(channelId)` exactly once when
 * the initial backfill finishes", see `connectors/AGENTS.md` and
 * `twister/docs/BUILDING_CONNECTORS.md`) was previously only documented,
 * never checked, this test statically verifies every connector with
 * `onChannelEnabled` also has a `channelSyncCompleted` call somewhere in its
 * own source, `src/` included recursively.
 */

const CONNECTORS_DIR = join(__dirname, "..", "connectors");

/**
 * Every non-test `.ts` file under a connector's `src/`, recursively.
 *
 * Recursion matters for the composite connectors (`google`, `outlook`), which
 * keep each product's sync in its own subdirectory (`src/mail`, `src/calendar`,
 * `src/tasks`). Those product modules are where `channelSyncCompleted` is
 * actually called, so a shallow read of `src/*.ts` would miss it and report a
 * false gap.
 */
function connectorSourceFiles(connector: string): string[] {
  const srcDir = join(CONNECTORS_DIR, connector, "src");
  if (!existsSync(srcDir)) return [];

  const walk = (dir: string): string[] =>
    readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) return walk(path);
      return entry.name.endsWith(".ts") && !entry.name.endsWith(".test.ts")
        ? [path]
        : [];
    });

  return walk(srcDir);
}

function sourceContains(connector: string, needle: string): boolean {
  return connectorSourceFiles(connector).some((f) =>
    readFileSync(f, "utf8").includes(needle)
  );
}

/**
 * Connectors with a legitimate reason not to call channelSyncCompleted from
 * within their own onChannelEnabled — e.g. completion signaled from a
 * different entry point, or genuinely no notion of "initial sync". Document
 * the reason inline at the allowlist entry, not just here.
 *
 * Empty as of this writing: every connector with `onChannelEnabled` calls
 * `channelSyncCompleted` somewhere in its own source. Do not add an entry
 * here to mask a real gap; fix the connector instead, or if it turns out to
 * be genuinely exempt, explain why in a comment next to the entry.
 */
const ALLOWLISTED_CONNECTORS: string[] = [];

describe("every connector with onChannelEnabled calls channelSyncCompleted", () => {
  const connectors = readdirSync(CONNECTORS_DIR, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .filter((name) => sourceContains(name, "onChannelEnabled"));

  // Sanity check the discovery mechanism itself found a realistic set of
  // connectors, so a refactor that silently breaks readdirSync/srcDir
  // resolution shows up as a failure here rather than an empty, vacuously
  // passing it.each below.
  it("found more than a handful of connectors with onChannelEnabled", () => {
    expect(connectors.length).toBeGreaterThan(10);
  });

  it.each(connectors.filter((c) => !ALLOWLISTED_CONNECTORS.includes(c)))(
    "%s calls channelSyncCompleted somewhere in its source",
    (connector) => {
      expect(sourceContains(connector, "channelSyncCompleted")).toBe(true);
    }
  );
});
