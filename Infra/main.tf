# --- STORAGE & BIGQUERY ---

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

# --- SERVICES & REPOSITORY ---

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

resource "google_artifact_registry_repository" "dbt_images" {
  location      = var.region
  repository_id = var.ar_repo_name
  description   = "dbt images"
  format        = "DOCKER"
}

# --- IAM & SECURITY ---

resource "google_service_account" "service_account" {
  account_id   = "omza-etl-sa"
  display_name = "omza ETL SA"
}

resource "google_project_iam_member" "storage_object_viewer" {
  project = var.project_id
  role    = "roles/storage.objectViewer"
  member  = "serviceAccount:${google_service_account.service_account.email}"
}

resource "google_project_iam_member" "workflow_invoker" {
  project = var.project_id
  role    = "roles/workflows.invoker"
  member  = "serviceAccount:${google_service_account.service_account.email}"
}

resource "google_project_iam_member" "eventarc_admin" {
  project = var.project_id
  role    = "roles/eventarc.admin"
  member  = "serviceAccount:${google_service_account.service_account.email}"
}

resource "google_project_iam_member" "run_developer" {
  project = var.project_id
  role    = "roles/run.developer"
  member  = "serviceAccount:${google_service_account.service_account.email}"
}

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

# --- SECRET MANAGER ---

# 1. On active d'abord l'API
resource "google_project_service" "secretmanager" {
  service            = "secretmanager.googleapis.com"
  disable_on_destroy = false
}

# 2. On crée le secret (en attendant que l'API soit prête)
resource "google_secret_manager_secret" "dbt_keyfile" {
  secret_id = "dbt-service-account-key"

  # Cette ligne est cruciale pour éviter l'erreur 403: Secret Manager API has not been used in project...
  depends_on = [google_project_service.secretmanager]

  replication {
    auto {}
  }

  labels = {
    managed_by = "terraform"
    component  = "dbt"
  }
}

# 3. On donne l'accès au Service Account
resource "google_secret_manager_secret_iam_member" "dbt_secret_accessor" {
  secret_id = google_secret_manager_secret.dbt_keyfile.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.service_account.email}"
}

# --- COMPUTE (CLOUD RUN JOB) ---

resource "google_cloud_run_v2_job" "dbt" {
  name     = var.dbt_job_name
  location = var.region

  template {
    template {
      service_account = google_service_account.service_account.email
      max_retries     = 1
      timeout         = "1800s"

      containers {
        image = var.dbt_image
        args  = ["run"]

        volume_mounts {
          name       = "dbt-sa-secret"
          mount_path = "/secrets"
        }

        env {
          name  = "GOOGLE_APPLICATION_CREDENTIALS"
          value = "/secrets/dbt-keyfile"
        }
      }

      volumes {
        name = "dbt-sa-secret"
        secret {
          secret       = google_secret_manager_secret.dbt_keyfile.secret_id
          default_mode = 0444
          items {
            version = "latest"
            path    = "dbt-keyfile"
          }
        }
      }
    }
  }
}

resource "google_cloud_run_v2_job_iam_member" "run_job_runner" {
  name     = google_cloud_run_v2_job.dbt.name
  location = google_cloud_run_v2_job.dbt.location
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.service_account.email}"
}

# --- ORCHESTRATION & TRIGGERS ---

resource "google_workflows_workflow" "workflow" {
  name            = "omza-dsy-workflow"
  description     = "omza Dataset Workflow"
  source_contents = local.workflow_yaml
  region          = var.region
  service_account = google_service_account.service_account.email
}

resource "google_eventarc_trigger" "trigger" {
  name            = "omza-dsy-trigger"
  location        = "eu"
  service_account = google_service_account.service_account.email

  matching_criteria {
    attribute = "type"
    value     = "google.cloud.storage.object.v1.finalized"
  }

  matching_criteria {
    attribute = "bucket"
    value     = google_storage_bucket.bucket.name
  }

  destination {
    workflow = google_workflows_workflow.workflow.id
  }
}

resource "google_cloudbuild_trigger" "terraform_all_branches" {
  name        = var.cloudbuild_trigger_name
  description = "Run Terraform pipeline on every branch push"

  github {
    owner = var.github_owner
    name  = var.github_repo_name
    push {
      branch = var.cloudbuild_trigger_branch_regex
    }
  }

  filename = "cloudbuild.yaml"

  substitutions = {
    _TF_STATE_BUCKET = var.tf_state_bucket
    _TF_STATE_PREFIX = var.tf_state_prefix
  }
}