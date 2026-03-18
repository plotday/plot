#!/usr/bin/env tsx
/**
 * Notification testing script.
 *
 * Tests the full push notification pipeline against a running local API.
 * Requires NOTIFICATION_DELAY_MULTIPLIER=0.001 in workers/api/.dev.vars
 * so delays are compressed: inform-requests ≈ 1.8s, inform-updates ≈ 3.6s,
 * rate-limit window ≈ 0.3s.
 *
 * Usage:
 *   PLOT_SESSION_TOKEN=<token> tsx scripts/test-notifications.ts [scenario]
 *
 * Scenarios: all, basic, foreground, rate-limit, quiet-hours, batching, retraction
 *
 * To get a session token: open the app in debug mode, check the console for
 * the Bearer token used in API calls, or copy from browser DevTools.
 */

const API_BASE = "http://localhost:8787/app";
const MULTIPLIER = 0.001; // Must match .dev.vars NOTIFICATION_DELAY_MULTIPLIER

const token = process.env.PLOT_SESSION_TOKEN;
if (!token) {
  console.error("Error: PLOT_SESSION_TOKEN environment variable is required.");
  console.error("  export PLOT_SESSION_TOKEN=<your-session-token>");
  process.exit(1);
}

const scenario = process.argv[2] ?? "all";

// ── helpers ──────────────────────────────────────────────────────────────────

function header(title: string) {
  console.log("\n" + "─".repeat(60));
  console.log(`  ${title}`);
  console.log("─".repeat(60));
}

function step(msg: string) {
  console.log(`\n→ ${msg}`);
}

function observe(msg: string) {
  console.log(`  ✓ OBSERVE: ${msg}`);
}

function wait(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function triggerPush(): Promise<{ sent: number; devices: string[] }> {
  const res = await fetch(`${API_BASE}/test/trigger-push`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({}),
  });
  if (!res.ok) {
    throw new Error(`HTTP ${res.status}: ${await res.text()}`);
  }
  return res.json() as Promise<{ sent: number; devices: string[] }>;
}

// ── scenarios ─────────────────────────────────────────────────────────────────

async function scenarioBasic() {
  header("SCENARIO: basic");
  step("Ensure the app is backgrounded or the screen is off on your test device.");
  step("Triggering push notification via /test/trigger-push ...");

  const result = await triggerPush();
  console.log(`  Sent to ${result.sent} device(s): ${result.devices.join(", ") || "(none registered)"}`);

  if (result.sent === 0) {
    console.log("\n  ⚠️  No devices registered. Open the app on a device first to register.");
    return;
  }

  const waitMs = 5_000; // generous buffer; FCM delivery + notification-content fetch
  step(`Waiting ${waitMs}ms for notification to arrive ...`);
  await wait(waitMs);

  observe("A local notification appeared on the device within a few seconds.");
  observe("Tapping the notification opens the app to the correct priority.");
}

async function scenarioForeground() {
  header("SCENARIO: foreground");
  step("Keep the app OPEN and in the foreground on your test device.");
  step("Triggering push notification ...");

  const result = await triggerPush();
  console.log(`  Sent to ${result.sent} device(s).`);

  await wait(5_000);

  observe("NO notification appeared (real-time sync happened instead).");
  observe("App data refreshed silently in the background.");
}

async function scenarioRateLimit() {
  header("SCENARIO: rate-limit");
  console.log("\n  Note: This scenario requires the DO path (real unread threads).");
  console.log("  Create 2+ unread threads, then trigger two syncs in quick succession.");
  console.log("  With MULTIPLIER=0.001, the rate-limit window is ~0.3s.");
  console.log("\n  This scenario cannot be fully automated via the trigger endpoint.");
  console.log("  Manual steps:");
  step("1. Create an unread thread in the app.");
  step("2. Watch server logs — two PushNotify alarms will fire.");
  step("3. First alarm fires → push sent.");
  step("4. Second alarm fires within 0.3s → push suppressed (rescheduled).");
  observe("Only ONE notification appears, not two.");
}

async function scenarioQuietHours() {
  header("SCENARIO: quiet-hours");
  step("In the app: open command palette → 'Time travel' → freeze time to 22:00.");
  step("Triggering push notification ...");

  const result = await triggerPush();
  console.log(`  Sent to ${result.sent} device(s).`);

  await wait(3_000);

  observe("NO notification appeared immediately (quiet hours in effect: 21:00–07:00).");
  observe("In the app: use 'Time travel' → freeze to 07:01 to simulate window end.");
  observe("Notification appears after the quiet-hours window expires.");
}

async function scenarioBatching() {
  header("SCENARIO: batching");
  step("Create 2+ unread threads under DIFFERENT sub-priorities of the SAME first-level priority.");
  step("Triggering push notification ...");

  const result = await triggerPush();
  console.log(`  Sent to ${result.sent} device(s).`);

  await wait(5_000);

  observe("ONE batched notification for the first-level priority (not one per thread).");
  observe("Notification title = first-level priority name.");
  observe("Notification body = AI summary of all unread threads under it.");
}

async function scenarioRetraction() {
  header("SCENARIO: retraction");
  step("Ensure an unread thread exists and a notification is visible on the device.");
  step("Mark the thread as read on the SAME device (or another device in the app).");
  step("Triggering push notification (simulates re-check after read) ...");

  const result = await triggerPush();
  console.log(`  Sent to ${result.sent} device(s).`);

  await wait(5_000);

  observe("The existing notification was CANCELLED (retracted) from the notification tray.");
  observe("No new notification appeared since the thread is now read.");
}

// ── main ──────────────────────────────────────────────────────────────────────

const scenarios: Record<string, () => Promise<void>> = {
  basic: scenarioBasic,
  foreground: scenarioForeground,
  "rate-limit": scenarioRateLimit,
  "quiet-hours": scenarioQuietHours,
  batching: scenarioBatching,
  retraction: scenarioRetraction,
};

async function main() {
  console.log(`\nNotification Test Runner`);
  console.log(`API: ${API_BASE}`);
  console.log(`Scenario: ${scenario}`);
  console.log(`Delay multiplier: ${MULTIPLIER} (inform-requests ≈ 1.8s, inform-updates ≈ 3.6s)`);

  if (scenario === "all") {
    for (const [name, fn] of Object.entries(scenarios)) {
      if (name === "rate-limit" || name === "quiet-hours" || name === "retraction") {
        // These require manual setup — just print instructions
        await fn();
      } else {
        await fn();
        await wait(2_000); // brief pause between automated scenarios
      }
    }
  } else if (scenarios[scenario]) {
    await scenarios[scenario]();
  } else {
    console.error(`Unknown scenario: ${scenario}`);
    console.error(`Available: all, ${Object.keys(scenarios).join(", ")}`);
    process.exit(1);
  }

  console.log("\n" + "─".repeat(60));
  console.log("  Done.");
  console.log("─".repeat(60) + "\n");
}

main().catch((err) => {
  console.error("Error:", err);
  process.exit(1);
});
