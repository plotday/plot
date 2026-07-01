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

# Site availability alerting (plot.day marketing site).
#
# Context: a vite 8.1.0 bundler regression crashed the site worker at module
# init and Cloudflare-1101'd every request for ~4 hours before a human noticed
# (PR #519). The site's PostHog is CLIENT-side only, so a worker crash — which
# happens before any client JS runs — produced ZERO PostHog signal. PRs
# #521/#523 added server-side detection (an external uptime monitor, a worker
# try/catch, and a deploy preview gate); these two alerts are the email/page
# layer on top, in the same mold as bg.deferred / push.transient above:
#
#   - Server-side (PostHog evaluates the event stream) => independent of the
#     site worker's health, which is the whole point when the worker is the
#     thing that's down.
#   - In-repo + Terraform-managed => can't silently drift; the infra-plan drift
#     check fails if someone edits/deletes them in the PostHog UI.
#
# Two independent signals:
#   - site_monitor_failed   — emitted by .github/workflows/monitor-site.yml, a
#     scheduled (every 10 min) external smoke test of https://plot.day. The
#     "site is unreachable/broken from the outside" signal.
#   - site_worker_exception — emitted by apps/site/workers/app.ts when the
#     worker catches a worker-level throw in production (the branded-503 path).
#     The "the worker itself is crashing" signal.
#
# GitHub also emails on each failed monitor run, so a fast path exists
# regardless; these are the centralized, drift-checked, IaC-managed layer.

resource "posthog_insight" "site_monitor_failed" {
  name        = "Site monitor failures (site_monitor_failed / hour)"
  description = "External uptime smoke test of https://plot.day (.github/workflows/monitor-site.yml, every 10 min) failures per hour. Baseline is 0. A single failure can be a transient network blip; >1 in an hour means >=2 consecutive monitor runs failed — a real, sustained outage. The site's client-only PostHog can't report a worker crash, which is exactly why this external check exists (PR #519)."

  # InsightVizNode + TrendsQuery counting the `site_monitor_failed` counter per
  # hour. Single series, no breakdown, so the alert's series_index=0 is an
  # unambiguous total.
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
          event = "site_monitor_failed"
          name  = "site_monitor_failed"
          math  = "total"
        }
      ]
      trendsFilter = {
        display = "ActionsLineGraph"
      }
    }
  })
}

resource "posthog_alert" "site_down" {
  name = "plot.day is down (site monitor failing)"

  insight      = posthog_insight.site_monitor_failed.id
  series_index = 0

  condition_type = "absolute_value"
  threshold_type = "absolute"

  # Fire when MORE THAN ONE monitor run failed in the hour (>=2 of the 10-min
  # runs) — a sustained outage, not a single transient blip. The 4-hour outage
  # this guards against would trip this within the first ~20 minutes. Set to 0
  # to page on any single failure (noisier). Editing this is a reviewed,
  # plan-previewed change.
  threshold_upper = 1

  calculation_interval = "hourly"
  # Evaluate the in-progress hour too, so a live outage pages within the hour
  # instead of only after it completes. Safe here: with this threshold a partial
  # hour can only over-count toward a real outage, never false-fire.
  check_ongoing_interval = true

  subscribed_users = [157794] # kris@plot.day

  enabled = true
}

resource "posthog_insight" "site_worker_exception" {
  name        = "Site worker exceptions (site_worker_exception / hour)"
  description = "Worker-level exceptions caught by apps/site/workers/app.ts in production (the branded-503 path) per hour. Baseline is ~0 — React Router returns its own 500 *response* for loader/render errors, so reaching that catch means something escaped the framework (a bundling/module-init crash, a missing prod secret, etc.). A sustained nonzero rate means the worker is crashing and users see the error page."

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
          event = "site_worker_exception"
          name  = "site_worker_exception"
          math  = "total"
        }
      ]
      trendsFilter = {
        display = "ActionsLineGraph"
      }
    }
  })
}

resource "posthog_alert" "site_worker_crashing" {
  name = "Site worker crashing (sustained worker exceptions)"

  insight      = posthog_insight.site_worker_exception.id
  series_index = 0

  condition_type = "absolute_value"
  threshold_type = "absolute"

  # Baseline is ~0. A handful of one-off exceptions an hour shouldn't page, but a
  # worker crashing on requests emits these by the hundreds, so a total outage
  # trips this near-instantly. Conservative first cut — RE-TUNE from the
  # site_worker_exception baseline once it's been in production for a bit.
  threshold_upper = 10

  calculation_interval   = "hourly"
  check_ongoing_interval = true

  subscribed_users = [157794] # kris@plot.day

  enabled = true
}
