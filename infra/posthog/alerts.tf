# Capacity-pressure alerting for the background DB lane (PR #400).
#
# PR #400 split DB connections into a reserved frontend lane and a capped
# background lane, and made the background queue dispatchers SHED a whole batch
# (defer-with-backoff) when the shared single-vCPU Postgres origin is hot. Each
# shed emits a `bg.deferred` PostHog counter (workers/api/src/queue/shed.ts and
# workers/classify/src/index.ts) — deliberately NOT a captureException, because
# an individual shed is expected, self-healing load-shed (capturing per-event was
# the PostHog 019ed53e retry storm).
#
# That left a gap: nothing PUSHES when shedding stops being a transient blip and
# becomes SUSTAINED — the signal that the self-healing backoff is no longer
# keeping up and a human must pull a capacity lever. This module closes it with a
# server-side PostHog threshold alert on the `bg.deferred` rate.
#
#   - Server-side (PostHog evaluates the event stream) => independent of Worker
#     isolate lifetime. A code-level "sustained for N minutes" counter would live
#     in an isolate module-global and reset on every cold isolate, so it could
#     miss real sustained pressure; this can't.
#   - In-repo + Terraform-managed => it can't silently drift. The daily
#     infra-plan drift check fails if someone deletes/edits it in the PostHog UI.
#
# Which lever to pull once it fires: open the insight and break down by the
# `reason` event property —
#   - reason=recent_timeout  -> connection starvation: rebalance the 50/30
#     Hyperdrive split (give background more) or raise total origin connections.
#   - reason=ewma_high        -> CPU/IO saturation: vertical Cloud SQL bump
#     (db-custom-1-3840 -> db-custom-2-7680) or the deferred read replica.

resource "posthog_insight" "bg_shed" {
  name        = "Background DB shedding (bg.deferred / hour)"
  description = "Capacity pressure on the shared Postgres origin: background queue batches deferred (shed) per hour by the PR #400 self-throttling backoff. Sustained values mean the backoff is no longer keeping up. Break down by `reason`: recent_timeout = connection starvation (rebalance the 50/30 Hyperdrive split); ewma_high = CPU/IO saturation (scale Cloud SQL / add the read replica)."

  # InsightVizNode + TrendsQuery counting the `bg.deferred` counter per hour.
  # Single series, no breakdown, so the alert's series_index=0 is an unambiguous
  # total (breakdown-vs-alert aggregation semantics are avoided on purpose; use
  # the description's `reason` breakdown interactively to diagnose the lever).
  query_json = jsonencode({
    kind = "InsightVizNode"
    source = {
      kind     = "TrendsQuery"
      interval = "hour"
      dateRange = {
        date_from = "-7d"
      }
      series = [
        {
          kind  = "EventsNode"
          event = "bg.deferred"
          name  = "bg.deferred"
          math  = "total"
        }
      ]
      trendsFilter = {
        display = "ActionsLineGraph"
      }
    }
  })
}

resource "posthog_alert" "bg_shed_sustained" {
  name = "Background DB at capacity (sustained shedding)"

  insight      = posthog_insight.bg_shed.id
  series_index = 0

  condition_type = "absolute_value"
  threshold_type = "absolute"

  # Fire when a completed hour shed more than this many background batches.
  # Transient pressure self-heals well below this; a whole hour over it means the
  # backoff isn't draining and a lever needs pulling. Conservative first cut —
  # RE-TUNE from the bg.deferred baseline once PR #400 is deployed and we've seen
  # what a normal busy hour looks like (the design doc plans to tune from these
  # counters). Editing this number is a reviewed, plan-previewed change.
  threshold_upper = 50

  calculation_interval = "hourly"
  # Only evaluate completed hours, so a partially-elapsed current hour can't
  # false-fire on a low-but-not-yet-complete count.
  check_ongoing_interval = false

  # Notify by email. PostHog alerts notify subscribed users by numeric user id
  # (the posthog_user data source only exposes a uuid, not this id, so it's
  # resolved once and pinned here).
  subscribed_users = [157794] # kris@plot.day

  enabled = true
}
