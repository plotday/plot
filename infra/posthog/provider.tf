provider "posthog" {
  # Personal API key from POSTHOG_API_KEY (set by the scripts/terraform wrapper
  # via `op read`). Read-scoped by default; a deliberate `apply` needs a
  # write-scoped key — see infra/README.md "Activating the posthog alerts".
  host            = "https://us.posthog.com"
  organization_id = "0193b38c-6978-0000-f072-aa92d5c4a876" # Plot
  project_id      = "245802"                               # Plot
}
