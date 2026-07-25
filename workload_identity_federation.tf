# Workload Identity Federation for GitHub Actions
# Enables keyless OIDC authentication from GitHub Actions CI/CD workflows

# Enable required APIs
resource "google_project_service" "sts" {
  service            = "sts.googleapis.com"
  disable_on_destroy = false

  depends_on = [google_project_service.iam]
}

# Workload Identity Pool - GitHub Actions
resource "google_iam_workload_identity_pool" "github_actions" {
  count = var.enable_workload_identity_federation ? 1 : 0

  workload_identity_pool_id = var.environment == "dev" ? "github-actions-dev-pool" : "github-actions-pool"
  display_name              = "GitHub Actions"
  disabled                  = false
  description               = "Workload Identity Pool for GitHub Actions OIDC authentication"

  depends_on = [google_project_service.sts]
}

# OIDC Provider - GitHub
resource "google_iam_workload_identity_pool_provider" "github_provider" {
  count = var.enable_workload_identity_federation ? 1 : 0

  workload_identity_pool_id          = google_iam_workload_identity_pool.github_actions[0].workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"
  display_name                       = "GitHub"
  disabled                           = false

  attribute_mapping = {
    "google.subject"             = "assertion.sub"
    "attribute.actor"            = "assertion.actor"
    "attribute.aud"              = "assertion.aud"
    "attribute.repository"       = "assertion.repository"
    "attribute.repository_owner" = "assertion.repository_owner"
    "attribute.ref"              = "assertion.ref"
  }

  # Dev allows any branch so feature branches can authenticate for testing.
  # Prod keeps the main-only restriction (separate pool in prod project).
  attribute_condition = var.environment == "dev" ? "assertion.repository_owner == '${var.github_repository_owner}'" : "assertion.repository_owner == '${var.github_repository_owner}' && assertion.ref == 'refs/heads/main'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# Service Account - GitHub Actions (Dev)
resource "google_service_account" "github_actions_dev" {
  count      = (var.enable_workload_identity_federation && var.enable_terraform_github_actions_identities && var.environment == "dev") ? 1 : 0
  account_id = "${var.app_name}-github-actions-dev"
}

# Service Account - GitHub Actions (Prod)
resource "google_service_account" "github_actions_prod" {
  count      = (var.enable_workload_identity_federation && var.enable_terraform_github_actions_identities && var.environment == "prod") ? 1 : 0
  account_id = "${var.app_name}-github-actions-prod"
}

# IAM bindings for GHA service accounts are managed outside Terraform via gcloud.
# The GHA SA runs as roles/editor which cannot call setIamPolicy on the project,
# so any google_project_iam_member for these SAs would always fail in CI.
# Grants are applied once by the project owner and documented in /docs/gha-permissions.md.

# Tell Terraform to drop these resources from state without destroying them in GCP.
# They were previously managed here but cannot be destroyed by the GHA SA.

resource "google_service_account_iam_member" "github_actions_dev_wif" {
  count = (var.enable_workload_identity_federation && var.enable_terraform_github_actions_identities && var.environment == "dev") ? 1 : 0

  service_account_id = google_service_account.github_actions_dev[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github_actions[0].name}/attribute.repository/${var.github_repository_owner}/${var.github_repository_name}"
}

# Allow the dbt repo to authenticate directly as the dbt service account via WIF
resource "google_service_account_iam_member" "dbt_wif" {
  count = var.enable_workload_identity_federation ? 1 : 0

  service_account_id = "projects/${var.gcp_project_id}/serviceAccounts/${var.environment == "dev" ? "chameleon-dbt-dev" : "chameleon-dbt-prod"}@${var.gcp_project_id}.iam.gserviceaccount.com"
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github_actions[0].name}/attribute.repository_owner/${var.github_repository_owner}"
}

resource "google_service_account_iam_member" "github_actions_prod_wif" {
  count = (var.enable_workload_identity_federation && var.enable_terraform_github_actions_identities && var.environment == "prod") ? 1 : 0

  service_account_id = google_service_account.github_actions_prod[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github_actions[0].name}/attribute.repository/${var.github_repository_owner}/${var.github_repository_name}"
}
