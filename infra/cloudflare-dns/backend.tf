terraform {
  # State in Cloudflare R2 (S3-compatible). Account 34ceb662899230b63c7e8114eaf9277c.
  backend "s3" {
    bucket    = "plot-tf-state"
    key       = "cloudflare-dns/plot-day.tfstate"
    region    = "auto"
    endpoints = { s3 = "https://34ceb662899230b63c7e8114eaf9277c.r2.cloudflarestorage.com" }

    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
    use_path_style              = true
    use_lockfile                = true

    # Credentials from AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (scripts/terraform).
  }
}
