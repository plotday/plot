import { readFileSync, readdirSync, existsSync } from "node:fs";
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
 * reachable source.
 */

const CONNECTORS_DIR = join(__dirname, "..", "connectors");
const PACKAGE_PREFIX = "@plotday/connector-";

function connectorSourceFiles(connector: string): string[] {
  const srcDir = join(CONNECTORS_DIR, connector, "src");
  if (!existsSync(srcDir)) return [];
  return readdirSync(srcDir)
    .filter((f) => f.endsWith(".ts") && !f.endsWith(".test.ts"))
    .map((f) => join(srcDir, f));
}

function sourceContains(connector: string, needle: string): boolean {
  return connectorSourceFiles(connector).some((f) =>
    readFileSync(f, "utf8").includes(needle)
  );
}

/**
 * Sibling connector packages this connector depends on, via
 * `"@plotday/connector-<name>": "workspace:*"`-style dependencies, resolved
 * to their directory names under `connectors/`.
 *
 * Composite connectors (`google`, `outlook`) bundle several products (mail,
 * calendar, tasks, contacts) under one OAuth grant. Their own
 * `onChannelEnabled` parses the namespaced channel id and delegates to
 * extracted `onChannelEnabled`/sync functions imported from the matching
 * standalone connector package (e.g. `google` delegates calendar channels to
 * `@plotday/connector-google-calendar`'s exports), passing a namespaced
 * "host" wrapper that proxies back to `this.tools`. Those delegated
 * functions are the ones that actually call `channelSyncCompleted` — the
 * literal string never appears in `google/src/*.ts` or `outlook/src/*.ts`
 * themselves. This resolves that delegation from `package.json` instead of
 * hardcoding an allowlist, so a future composite connector is covered
 * automatically.
 */
function delegatedConnectors(connector: string): string[] {
  const pkgPath = join(CONNECTORS_DIR, connector, "package.json");
  if (!existsSync(pkgPath)) return [];
  const pkg = JSON.parse(readFileSync(pkgPath, "utf8")) as {
    dependencies?: Record<string, string>;
  };
  return Object.keys(pkg.dependencies ?? {})
    .filter((name) => name.startsWith(PACKAGE_PREFIX))
    .map((name) => name.slice(PACKAGE_PREFIX.length));
}

/**
 * Connectors with a legitimate reason not to call channelSyncCompleted from
 * within their own (or a delegated sibling's) onChannelEnabled — e.g.
 * completion signaled from a different entry point, or genuinely no notion
 * of "initial sync". Document the reason inline at the allowlist entry, not
 * just here.
 *
 * Empty as of this writing: every connector with `onChannelEnabled` either
 * calls `channelSyncCompleted` directly, or (for the `google`/`outlook`
 * composite connectors) delegates to a sibling connector package that does —
 * see `delegatedConnectors` above. Do not add an entry here to mask a real
 * gap; fix the connector instead, or if it turns out to be genuinely
 * exempt, explain why in a comment next to the entry.
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
    "%s calls channelSyncCompleted somewhere in its own or a delegated connector's source",
    (connector) => {
      const ownCall = sourceContains(connector, "channelSyncCompleted");
      const delegatedCall = delegatedConnectors(connector).some((dep) =>
        sourceContains(dep, "channelSyncCompleted")
      );
      expect(ownCall || delegatedCall).toBe(true);
    }
  );
});
