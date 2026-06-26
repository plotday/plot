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

# Sustained-failure alerting for the push-delivery path (PostHog issue 019ebd3b).
#
# The push DOs (PushNotify, UserSync) suppress transient Cloudflare/Hyperdrive
# platform faults — "Durable Object storage operation exceeded timeout which
# caused object to be reset", pg "Connection terminated", "Network connection
# lost" — instead of paging Error Tracking, because an individual occurrence is
# expected, self-healing noise (the DO resets and the next notify() schedules a
# fresh alarm; capturing per-event was the original 019ebd3b page-storm).
#
# That suppression left the same gap PR #400 hit with bg.deferred: nothing
# PUSHES when these blips stop being transient and become SUSTAINED — the signal
# that push wakes are silently failing and users have stopped getting
# notifications. Each suppressed occurrence emits a `push.transient` counter
# (workers/api/src/state/{push-notify,user-sync}.ts, NOT a captureException);
# this module pages on its rate, exactly like bg.deferred above.
#
#   - Server-side (PostHog evaluates the event stream) => independent of DO
#     isolate lifetime. A code-level "N-in-a-row" counter would live in DO state
#     that a platform reset wipes, so it could miss real sustained pressure;
#     this can't.
#   - In-repo + Terraform-managed => can't silently drift; the infra-plan drift
#     check fails if someone edits/deletes it in the PostHog UI.
#
# Diagnosing once it fires: open the insight and break down by the `reason`
# event property — do_storage_timeout / platform_internal = Cloudflare DO
# contention (check the Workers dashboard / recent deploys); db_drop =
# Hyperdrive/pg saturation (cross-check the bg.deferred alert and the 50/30
# split); network_lost = DO-to-DO fetch blips. Break down by `durable_object`
# to see whether it's PushNotify, UserSync, or both.

resource "posthog_insight" "push_transient" {
  name        = "Push-delivery transient errors (push.transient / hour)"
  description = "Suppressed transient platform faults on the push-delivery path (PushNotify + UserSync DOs) per hour. Baseline is ~0; a sustained nonzero rate means push/sync wakes are silently failing and users may not be getting notifications. Break down by `reason` (do_storage_timeout / platform_internal / db_drop / network_lost) and by `durable_object` to localize. See PostHog issue 019ebd3b."

  # InsightVizNode + TrendsQuery counting the `push.transient` counter per hour.
  # Single series, no breakdown, so the alert's series_index=0 is an unambiguous
  # total (use the description's `reason` / `durable_object` breakdowns
  # interactively to diagnose).
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
          event = "push.transient"
          name  = "push.transient"
          math  = "total"
        }
      ]
      trendsFilter = {
        display = "ActionsLineGraph"
      }
    }
  })
}

resource "posthog_alert" "push_transient_sustained" {
  name = "Push delivery degraded (sustained transient errors)"

  insight      = posthog_insight.push_transient.id
  series_index = 0

  condition_type = "absolute_value"
  threshold_type = "absolute"

  # Fire when a completed hour suppressed more than this many push-path transient
  # errors. The baseline is ~0 (issue 019ebd3b was 7 occurrences over two WEEKS),
  # so a whole completed hour over this is a clear, sustained degradation rather
  # than an isolated blip. Conservative first cut — RE-TUNE once the
  # push.transient baseline is visible in production. Editing this number is a
  # reviewed, plan-previewed change.
  threshold_upper = 20

  calculation_interval = "hourly"
  # Only evaluate completed hours, so a partially-elapsed current hour can't
  # false-fire on a low-but-not-yet-complete count.
  check_ongoing_interval = false

  subscribed_users = [157794] # kris@plot.day

  enabled = true
}
