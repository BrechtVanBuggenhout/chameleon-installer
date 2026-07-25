# Data Pipeline (PII Ingestor Worker) Deploy Infrastructure
# Provisions the Artifact Registry repo, deployer service account, and WIF binding
# for the chameleon-data-pipelines GitHub Actions CD workflow.

# Artifact Registry Docker repository for PII Ingestor Worker container images.
resource "google_artifact_registry_repository" "data_pipeline" {
  location      = var.gcp_region
  repository_id = "pii-ingestor-worker-${local.instance_name}"
  description   = "Docker images for the Chameleon PII Ingestor Worker (${local.instance_name})"
  format        = "DOCKER"

  cleanup_policy_dry_run = false

  cleanup_policies {
    id     = "keep-recent-images"
    action = "KEEP"

    most_recent_versions {
      keep_count = 20
    }
  }

  cleanup_policies {
    id     = "delete-untagged-after-30-days"
    action = "DELETE"

    condition {
      tag_state  = "UNTAGGED"
      older_than = "2592000s"
    }
  }

  labels = merge(var.labels, {
    environment = var.environment
    component   = "data-pipeline"
  })

  depends_on = [google_project_service.artifactregistry]
}

# Service Account for GitHub Actions data-pipeline deployments.
resource "google_service_account" "data_pipeline_deployer" {
  # 26 static chars + instance_short (<=4) stays within the 30-char account_id
  # ceiling; unlike key_vault's deployer SA, no prefix-shortening is needed.
  account_id   = "${var.app_name}-pipeline-deploy-${local.instance_short}"
  display_name = "Chameleon Data Pipeline Deployer (${local.instance_name})"
  description  = "GitHub Actions deploy identity for PII Ingestor Worker container pushes and Cloud Run deployments"
}

# IAM: Deployer can push images to the data pipeline Artifact Registry repo.
resource "google_artifact_registry_repository_iam_member" "data_pipeline_deployer_artifact_writer" {
  location   = google_artifact_registry_repository.data_pipeline.location
  repository = google_artifact_registry_repository.data_pipeline.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.data_pipeline_deployer.email}"
}

# IAM: Cloud Run agent can pull images from the data pipeline Artifact Registry repo.
resource "google_artifact_registry_repository_iam_member" "data_pipeline_cloud_run_artifact_reader" {
  location   = google_artifact_registry_repository.data_pipeline.location
  repository = google_artifact_registry_repository.data_pipeline.name
  role       = "roles/artifactregistry.reader"
  member     = google_project_service_identity.run.member
}

# BYOC onboarding: grant a customer project's own runtime service account(s)
# read access to Chameleon's pre-built images (see key_vault.tf's matching
# external-readers grant for the rationale).
resource "google_artifact_registry_repository_iam_member" "data_pipeline_external_readers" {
  for_each   = toset(var.data_pipeline_artifact_registry_external_readers)
  location   = google_artifact_registry_repository.data_pipeline.location
  repository = google_artifact_registry_repository.data_pipeline.name
  role       = "roles/artifactregistry.reader"
  member     = each.value
}

# IAM: Deployer can update the PII Ingestor Worker Cloud Run service.
resource "google_project_iam_member" "data_pipeline_deployer_run_developer" {
  project = var.gcp_project_id
  role    = "roles/run.developer"
  member  = "serviceAccount:${google_service_account.data_pipeline_deployer.email}"
}

# IAM: Deployer can act as the pii_ingestor_worker runtime SA (required by Cloud Run deploy).
resource "google_service_account_iam_member" "data_pipeline_deployer_runtime_user" {
  service_account_id = google_service_account.pii_ingestor_worker.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.data_pipeline_deployer.email}"
}

# IAM: WIF binding — GitHub Actions in the data-pipelines repo can impersonate the deployer SA.
resource "google_service_account_iam_member" "data_pipeline_deployer_wif" {
  count = var.enable_workload_identity_federation ? 1 : 0

  service_account_id = google_service_account.data_pipeline_deployer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github_actions[0].name}/attribute.repository/${var.github_repository_owner}/${var.data_pipeline_github_repository_name}"
}

# Output the Artifact Registry URL so it can be stored as a GitHub Actions variable.
output "data_pipeline_artifact_repository_url" {
  description = "Artifact Registry URL for PII Ingestor Worker images"
  value       = "${var.gcp_region}-docker.pkg.dev/${var.gcp_project_id}/${google_artifact_registry_repository.data_pipeline.repository_id}"
}

output "data_pipeline_deployer_service_account_email" {
  description = "Service account email for the data pipeline GitHub Actions deployer"
  value       = google_service_account.data_pipeline_deployer.email
}
