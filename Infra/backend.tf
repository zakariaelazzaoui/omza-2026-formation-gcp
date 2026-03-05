terraform {
  backend "gcs" {
    # Configured via -backend-config flags
    # bucket = "omza-etl-tfstate"
    # prefix = "terraform/infra"
  }
}