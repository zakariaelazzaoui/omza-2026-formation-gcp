# Workflow orchestrates the ELT pipeline
resource "google_workflows_workflow" "workflow" {
  name            = "omza-dsy-workflow"
  description     = "omza Dataset Workflow"
  source_contents = local.workflow_yaml  # Loaded from locals.tf
  region          = var.region
  service_account = google_service_account.service_account.email
}