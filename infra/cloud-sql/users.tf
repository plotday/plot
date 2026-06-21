# Built-in (password-auth) database roles. The Google-created `postgres`
# superuser is intentionally left unmanaged.
#
# Passwords are NOT readable on import and are managed out-of-band (1Password /
# rotation), so they're omitted here and ignored — Terraform manages the user's
# existence, not its credential.
locals {
  sql_users = ["api", "migrator", "readonly"]
}

resource "google_sql_user" "users" {
  for_each = toset(local.sql_users)

  name     = each.key
  project  = "plot-core"
  instance = google_sql_database_instance.plot_prod.name

  lifecycle {
    ignore_changes = [password]
  }
}
