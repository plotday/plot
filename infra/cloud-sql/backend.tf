terraform {
  # State in Cloudflare R2 via the S3-compatible backend.
  # Account ID 34ceb662899230b63c7e8114eaf9277c (from the Cloudflare dashboard URL).
  backend "s3" {
    bucket    = "plot-tf-state"
    key       = "cloud-sql/plot-prod.tfstate"
    region    = "auto"
    endpoints = { s3 = "https://34ceb662899230b63c7e8114eaf9277c.r2.cloudflarestorage.com" }

    # R2 is S3-compatible but needs these to bypass AWS-specific behaviors
    # (per Cloudflare's "Remote R2 backend" docs):
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true # R2 rejects AWS's default checksum trailer
    use_path_style              = true

    use_lockfile = true # state locking via S3 conditional writes (R2 supports them)

    # Credentials (R2 API token) come from AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
    # in the environment — set by `scripts/terraform` via `op read`. Never inline
    # secrets in this committed file.
  }
}
