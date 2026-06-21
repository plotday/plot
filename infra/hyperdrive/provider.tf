provider "cloudflare" {
  # API token from CLOUDFLARE_API_TOKEN (read-scoped by default; set by the
  # scripts/terraform wrapper via `op read`). Override with an edit-scoped token
  # for a deliberate apply (e.g. a capacity change to origin_connection_limit).
}
