docker "postgres" "dev" {
  image = "plot-atlas-dev"
  build {
    context    = "."
    dockerfile = "Dockerfile"
  }
  baseline = <<-SQL
    CREATE SCHEMA IF NOT EXISTS "extensions";
    CREATE SCHEMA IF NOT EXISTS "admin";
    CREATE SCHEMA IF NOT EXISTS "user";
  SQL
}

env "local" {
  src = [
    "file://schema/10-settings",
    "file://schema/20-extensions",
    "file://schema/30-types",
    "file://schema/40-functions",
    "file://schema/50-tables",
    "file://schema/60-functions",
    "file://schema/70-views",
    "file://schema/90-user-schema",
    "file://schema/95-triggers",
    "file://schema/99-data",
  ]
  dev     = docker.postgres.dev.url
  schemas = ["public", "user", "admin", "extensions"]

  migration {
    dir = "file://migrations"
  }
}
