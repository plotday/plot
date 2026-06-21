# Production Cloud SQL instance, imported faithfully from the live resource
# (captured 2026-06-20). `terraform plan` must report no changes.
#
# Capacity/durability notes (recorded here, deliberately NOT changed by this
# faithful import — see infra/README.md):
#   - availability_type = ZONAL  → single zone, no standby, no auto-failover.
#   - No `max_connections` flag  → the Cloud SQL tier default (~100 for this
#     RAM) applies. Hyperdrive's origin_connection_limit (scripts/deploy-hyperdrive,
#     currently 80) must stay below it. Making this explicit is a phase-2 change.
resource "google_sql_database_instance" "plot_prod" {
  name                = "plot-prod"
  project             = "plot-core"
  region              = "northamerica-northeast2"
  database_version    = "POSTGRES_18"
  deletion_protection = true # Terraform-level guard against destroy

  settings {
    tier              = "db-custom-1-3840" # 1 vCPU / 3.75 GB
    edition           = "ENTERPRISE"
    availability_type = "ZONAL"
    activation_policy = "ALWAYS"

    disk_type                   = "PD_SSD"
    disk_size                   = 10
    disk_autoresize             = true
    disk_autoresize_limit       = 0
    deletion_protection_enabled = true # API-level guard
    retain_backups_on_delete    = true # keep automated backups if the instance is deleted

    database_flags {
      name  = "cloudsql.iam_authentication"
      value = "on"
    }

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      start_time                     = "21:00"
      transaction_log_retention_days = 7
      location                       = "us"

      backup_retention_settings {
        retained_backups = 7
        retention_unit   = "COUNT"
      }
    }

    ip_configuration {
      ipv4_enabled = true
      ssl_mode     = "ENCRYPTED_ONLY"

      # Cloudflare published egress ranges — Hyperdrive reaches the DB over
      # public IP. Order mirrors the API; reorder if `plan` shows a reorder.
      authorized_networks { value = "103.21.244.0/22" }
      authorized_networks { value = "104.16.0.0/13" }
      authorized_networks { value = "104.24.0.0/14" }
      authorized_networks { value = "103.31.4.0/22" }
      authorized_networks { value = "141.101.64.0/18" }
      authorized_networks { value = "198.41.128.0/17" }
      authorized_networks { value = "173.245.48.0/20" }
      authorized_networks { value = "108.162.192.0/18" }
      authorized_networks { value = "131.0.72.0/22" }
      authorized_networks { value = "188.114.96.0/20" }
      authorized_networks { value = "162.158.0.0/15" }
      authorized_networks { value = "172.64.0.0/13" }
      authorized_networks { value = "197.234.240.0/22" }
      authorized_networks { value = "103.22.200.0/22" }
      authorized_networks { value = "190.93.240.0/20" }
    }

    location_preference {
      zone = "northamerica-northeast2-b"
    }

    maintenance_window {
      day          = 6 # Saturday
      hour         = 2
      update_track = "stable"
    }

    insights_config {
      query_insights_enabled = true
      query_plans_per_minute = 5
      query_string_length    = 1024
    }

    password_validation_policy {
      enable_password_policy      = true
      complexity                  = "COMPLEXITY_DEFAULT"
      disallow_username_substring = true
      min_length                  = 8
    }
  }
}
