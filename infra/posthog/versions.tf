terraform {
  required_version = ">= 1.11"

  required_providers {
    posthog = {
      source  = "PostHog/posthog"
      version = "~> 1.0"
    }
  }
}
