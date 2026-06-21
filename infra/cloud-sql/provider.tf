provider "google" {
  project = "plot-core"
  region  = "northamerica-northeast2"

  # Identity is supplied by the environment, NOT pinned here:
  #   - GOOGLE_IMPERSONATE_SERVICE_ACCOUNT (readonly SA by default; the
  #     `scripts/terraform` wrapper sets it)
  #   - the operator's gcloud ADC / user creds, which must hold
  #     roles/iam.serviceAccountTokenCreator on that SA.
  # Leaving it unpinned lets a deliberate phase-2 apply run under a writable
  # identity. See infra/README.md.
}
