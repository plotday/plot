# The application database. The Google-created `postgres` default database is
# intentionally left unmanaged.
resource "google_sql_database" "plot" {
  name      = "plot"
  project   = "plot-core"
  instance  = google_sql_database_instance.plot_prod.name
  charset   = "UTF8"
  collation = "en_US.UTF8"
}
