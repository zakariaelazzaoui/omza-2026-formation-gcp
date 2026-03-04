# GCS bucket for raw data
resource "google_storage_bucket" "bucket" {
  name          = "omza-etl-dsy"
  location      = "EU"
  force_destroy = true
}

# BigQuery dataset
resource "google_bigquery_dataset" "dataset" {
  dataset_id    = "omza_dsy"
  friendly_name = "omza Dataset"
  description   = "omza Dataset"
  location      = "EU"
}

# Raw country reference table
resource "google_bigquery_table" "raw_country" {
  dataset_id = "omza_dsy"
  table_id   = "raw_country"
  schema     = <<EOF
  [
    {"name": "id", "type": "STRING"},
    {"name": "iso", "type": "STRING"},
    {"name": "name", "type": "STRING"},
    {"name": "nicename", "type": "STRING"},
    {"name": "iso3", "type": "STRING"},
    {"name": "numcode", "type": "STRING"},
    {"name": "phonecode", "type": "STRING"}
  ]
  EOF
}

# Raw invoice transactions table
resource "google_bigquery_table" "raw_invoice" {
  dataset_id = "omza_dsy"
  table_id   = "raw_invoice"
  schema     = <<EOF
  [
    {"name": "InvoiceNo", "type": "STRING"},
    {"name": "StockCode", "type": "STRING"},
    {"name": "Description", "type": "STRING"},
    {"name": "Quantity", "type": "STRING"},
    {"name": "InvoiceDate", "type": "STRING"},
    {"name": "UnitPrice", "type": "STRING"},
    {"name": "CustomerID", "type": "STRING"},
    {"name": "Country", "type": "STRING"}
  ]
  EOF
}
# Enable required APIs
resource "google_project_service" "service" {
  service = "iam.googleapis.com"
}

resource "google_project_service" "cloud_run_api" {
  service = "run.googleapis.com"
}

resource "google_project_service" "cloudbuild_api" {
  service = "cloudbuild.googleapis.com"
}

resource "google_project_service" "artifact_registry_api" {
  service = "artifactregistry.googleapis.com"
}

# Docker repository for custom dbt images
resource "google_artifact_registry_repository" "dbt_images" {
  location      = var.region
  repository_id = var.ar_repo_name
  description   = "dbt images"
  format        = "DOCKER"
}
# Service account for workflows and Cloud Run Job
resource "google_service_account" "service_account" {
  account_id   = "omza-etl-sa"
  display_name = "omza ETL SA"
}

# Grant GCS read access
resource "google_project_iam_member" "storage_object_viewer" {
  project = var.project_id
  role    = "roles/storage.objectViewer"
  member  = "serviceAccount:${google_service_account.service_account.email}"
}

# Grant workflow invocation
resource "google_project_iam_member" "workflow_invoker" {
  project = var.project_id
  role    = "roles/workflows.invoker"
  member  = "serviceAccount:${google_service_account.service_account.email}"
}

# Grant Eventarc admin (for trigger management)
resource "google_project_iam_member" "eventarc_admin" {
  project = var.project_id
  role    = "roles/eventarc.admin"
  member  = "serviceAccount:${google_service_account.service_account.email}"
}

# Cloud Run Job executes dbt transformations
resource "google_cloud_run_v2_job" "dbt" {
  name     = var.dbt_job_name
  location = var.region

  template {
    template {
      service_account = google_service_account.service_account.email
      max_retries     = 1
      timeout         = "1800s"  # 30 minutes

      containers {
        image = var.dbt_image
        args  = ["run"]  # dbt run command

        # Mount secret as volume
        volume_mounts {
          name       = "dbt-sa-secret"
          mount_path = "/secrets"
        }

        # Environment variable pointing to mounted keyfile
        env {
          name  = "GOOGLE_APPLICATION_CREDENTIALS"
          value = "/secrets/dbt-keyfile"
        }
      }

      # Volume definition for secret
      volumes {
        name = "dbt-sa-secret"
        secret {
          secret       = google_secret_manager_secret.dbt_keyfile.secret_id
          default_mode = 0444  # Read-only
          items {
            version = "latest"
            path    = "dbt-keyfile"
          }
        }
      }
    }
  }
}

# Allow service account to invoke the job
resource "google_cloud_run_v2_job_iam_member" "run_job_runner" {
  name     = google_cloud_run_v2_job.dbt.name
  location = google_cloud_run_v2_job.dbt.location
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.service_account.email}"
}

# Grant Cloud Run developer role
resource "google_project_iam_member" "run_developer" {
  project = var.project_id
  role    = "roles/run.developer"
  member  = "serviceAccount:${google_service_account.service_account.email}"
}

# Secret Manager secret to store dbt service account key
resource "google_secret_manager_secret" "dbt_keyfile" {
  secret_id = "dbt-service-account-key"

  replication {
    auto {}  # Automatic replication across regions
  }

  labels = {
    managed_by = "terraform"
    component  = "dbt"
  }
}

# Grant the Cloud Run service account access to read the secret
resource "google_secret_manager_secret_iam_member" "dbt_secret_accessor" {
  secret_id = google_secret_manager_secret.dbt_keyfile.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.service_account.email}"
}

# Grant BigQuery permissions to service account
resource "google_project_iam_member" "dbt_bigquery_user" {
  project = var.project_id
  role    = "roles/bigquery.dataEditor"
  member  = "serviceAccount:${google_service_account.service_account.email}"
}

resource "google_project_iam_member" "dbt_bigquery_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.service_account.email}"
}

# Workflow orchestrates the ELT pipeline
resource "google_workflows_workflow" "workflow" {
  name            = "omza-dsy-workflow"
  description     = "omza Dataset Workflow"
  source_contents = local.workflow_yaml  # Loaded from locals.tf
  region          = var.region
  service_account = google_service_account.service_account.email
}

# Trigger workflow on GCS file uploads
resource "google_eventarc_trigger" "trigger" {
  name            = "omza-dsy-trigger"
  location        = "eu"
  service_account = google_service_account.service_account.email

  # Match on file finalized events
  matching_criteria {
    attribute = "type"
    value     = "google.cloud.storage.object.v1.finalized"
  }

  # Only for our specific bucket
  matching_criteria {
    attribute = "bucket"
    value     = google_storage_bucket.bucket.name
  }

  # Trigger workflow
  destination {
    workflow = google_workflows_workflow.workflow.id
  }
}

# CI/CD trigger for all branches
resource "google_cloudbuild_trigger" "terraform_all_branches" {
  name        = var.cloudbuild_trigger_name
  description = "Run Terraform pipeline on every branch push"

  github {
    owner = var.github_owner
    name  = var.github_repo_name
    push {
      branch = var.cloudbuild_trigger_branch_regex  # ".*" = all branches
    }
  }

  filename = "cloudbuild.yaml"

  substitutions = {
    _TF_STATE_BUCKET = var.tf_state_bucket
    _TF_STATE_PREFIX = var.tf_state_prefix
  }
}

# Trigger workflow on GCS file uploads
resource "google_eventarc_trigger" "trigger" {
  name            = "omza-dsy-trigger"
  location        = "eu"
  service_account = google_service_account.service_account.email

  # Match on file finalized events
  matching_criteria {
    attribute = "type"
    value     = "google.cloud.storage.object.v1.finalized"
  }

  # Only for our specific bucket
  matching_criteria {
    attribute = "bucket"
    value     = google_storage_bucket.bucket.name
  }

  # Trigger workflow
  destination {
    workflow = google_workflows_workflow.workflow.id
  }
}
# CI/CD trigger for all branches
resource "google_cloudbuild_trigger" "terraform_all_branches" {
  name        = var.cloudbuild_trigger_name
  description = "Run Terraform pipeline on every branch push"

  github {
    owner = var.github_owner
    name  = var.github_repo_name
    push {
      branch = var.cloudbuild_trigger_branch_regex  # ".*" = all branches
    }
  }

  filename = "cloudbuild.yaml"

  substitutions = {
    _TF_STATE_BUCKET = var.tf_state_bucket
    _TF_STATE_PREFIX = var.tf_state_prefix
  }
}