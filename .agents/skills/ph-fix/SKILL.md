---
name: ph-fix
description: Fix a PostHog error tracking issue. Takes a PostHog error URL, extracts the error UUID, looks up details via PostHog MCP, finds and fixes the bug, then marks it resolved.
---

# PostHog Error Fix

## Input

The user provides a PostHog error tracking URL, e.g.:
`https://us.posthog.com/project/245802/error_tracking/019cd82e-0b29-7e51-be1a-87d3ec764950?timestamp=...`

## Steps

### 1. Parse the URL

Extract the UUID from the URL path segment after `error_tracking/`. Strip any query parameters.

### 2. Look up error details

Use **both** of these PostHog MCP tools (call in parallel):

- `mcp__posthog__error-tracking-issues-retrieve` with the extracted UUID to get issue metadata (name, status, description)
- `mcp__posthog__error-details` with the UUID as `issueId` to get stack traces and occurrence details

**Focus on the most recent occurrences.** PostHog frequently groups unrelated errors under the same issue, so the issue title and older occurrences may be misleading or already fixed. When reviewing details:

- Sort/scan occurrences by timestamp and prioritize the latest ones.
- Treat the issue title and description as a hint, not ground truth — derive the real problem from the most recent stack trace and occurrence properties.
- If recent occurrences diverge from older ones (different stack frame, different message, different file), trust the recent ones. The older signal is likely a stale grouping.
- If only old occurrences exist and nothing recent, the bug may already be fixed — verify against current code before doing more work, and consider just marking it resolved.

Summarize the error for context based on the most recent occurrences: what crashed, where, and the stack trace.

### 3. Find and fix the bug

Invoke the `systematic-debugging` skill to trace the error through the codebase and implement a fix. Pass along, sourced from the **most recent** occurrence(s):
- The error name/message
- The full stack trace
- Any relevant occurrence metadata

Explicitly note in the handoff that the issue title may not match the actual bug, so debugging should follow the recent stack trace rather than the title.

### 4. Mark resolved

After the fix is implemented and verified, use `mcp__posthog__error-tracking-issues-partial-update` with the UUID to set `status` to `"resolved"`.
