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

Summarize the error for context: what crashed, where, and the stack trace.

### 3. Find and fix the bug

Invoke the `systematic-debugging` skill to trace the error through the codebase and implement a fix. Pass along:
- The error name/message
- The full stack trace
- Any relevant occurrence metadata

### 4. Mark resolved

After the fix is implemented and verified, use `mcp__posthog__error-tracking-issues-partial-update` with the UUID to set `status` to `"resolved"`.
