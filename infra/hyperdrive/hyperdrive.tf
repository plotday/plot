# Shared Hyperdrive configs fronting Cloud SQL plot-prod (used by the api +
# classify workers). Imported faithfully — no behavior change.
#
# `origin_connection_limit` — 50 (frontend) + 30 (background) = 80 total — is
# the connection-pool knob also managed today by scripts/deploy-hyperdrive.
# Capacity changes are OUT OF SCOPE here (separate effort) — this only records
# the current values.
#
# `origin.password` is a write-only secret the Cloudflare API never returns, so
# it can't be read on import. It's set to a placeholder and ignored via
# lifecycle.ignore_changes, which keeps `plan` at zero-diff WITHOUT ever pushing
# a password. IMPORTANT for any future apply: Terraform would use the (null)
# state value for password, so for pool-size changes prefer the safe partial
# update `scripts/deploy-hyperdrive`; only manage the origin here after wiring
# the real password in and confirming the provider's update path.
resource "cloudflare_hyperdrive_config" "plot_prod" {
  account_id = "34ceb662899230b63c7e8114eaf9277c"
  name       = "plot-prod"

  origin = {
    scheme               = "postgres"
    host                 = "34.130.85.92"
    port                 = 5432
    database             = "plot"
    user                 = "api"
    password             = "MANAGED_OUTSIDE_TERRAFORM" # ignored (see header)
    access_client_id     = null
    access_client_secret = null
    service_id           = null
  }

  caching = {
    disabled               = true
    max_age                = null
    stale_while_revalidate = null
  }

  mtls = {
    ca_certificate_id   = null
    mtls_certificate_id = null
    sslmode             = null
  }

  origin_connection_limit = 50

  lifecycle {
    ignore_changes = [origin.password]
  }
}

resource "cloudflare_hyperdrive_config" "plot_prod_bg" {
  account_id = "34ceb662899230b63c7e8114eaf9277c"
  name       = "plot-prod-bg"

  origin = {
    # Live config was created with the "postgresql" scheme (vs "postgres" on the
    # frontend). They're equivalent Postgres URI aliases; recorded as-is to keep
    # this a faithful, zero-diff baseline.
    scheme               = "postgresql"
    host                 = "34.130.85.92"
    port                 = 5432
    database             = "plot"
    user                 = "api"
    password             = "MANAGED_OUTSIDE_TERRAFORM" # ignored (see header)
    access_client_id     = null
    access_client_secret = null
    service_id           = null
  }

  caching = {
    disabled               = true
    max_age                = null
    stale_while_revalidate = null
  }

  mtls = {
    ca_certificate_id   = null
    mtls_certificate_id = null
    sslmode             = null
  }

  origin_connection_limit = 30

  lifecycle {
    ignore_changes = [origin.password]
  }
}
