cd infra

cat > terraform.tfvars << EOF
project_id                      = "omza-2026-formation"
region                          = "europe-west1"
dbt_job_name                    = "omza-etl-dbt-job"
github_owner                    = "zakariaelazzaoui"
github_repo_name                = "omza-etl-gcp"
cloudbuild_trigger_name         = "omza-etl-all-branches"
cloudbuild_trigger_branch_regex = ".*"
tf_state_bucket                 = "omza-etl-tfstate"
ar_repo_name                    = "dbt-images"
EOF