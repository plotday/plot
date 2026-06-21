terraform {
  # >= 1.11 for the S3 backend's native `use_lockfile` state locking.
  required_version = ">= 1.11"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}
