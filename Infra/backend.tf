terraform {
  backend "gcs" {
    # Configured via -backend-config flags
    # bucket = "retail-etl-tfstate"
    # prefix = "terraform/infra"
  }
}
