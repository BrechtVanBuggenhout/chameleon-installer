# Console Cloud Run deployment — chameleon-console containerized (see
# ../chameleon-console/Dockerfile). Public invoker by default: the real
# access control is the console's own app-level CONSOLE_PASSWORD gate
# (proxy.ts), not Cloud Run IAM — a browser can't present an identity token.

resource "google_service_account" "console" {
  account_id   = "${var.app_name}-console-${local.instance_short}"
  display_name = "Chameleon Console (${local.instance_name})"
  description  = "Service account for the containerized console Cloud Run service"
}

# Service Account for GitHub Actions console deployments. Mirrors
# key_vault_deployer / data_pipeline's deployer pattern exactly.
resource "google_service_account" "console_deployer" {
  account_id   = "${var.app_name}-console-deploy-${local.instance_short}"
  display_name = "Chameleon Console Deployer (${local.instance_name})"
  description  = "GitHub Actions deploy identity for console image pushes and Cloud Run deployments"
}

resource "google_artifact_registry_repository" "console" {
  location      = var.gcp_region
  repository_id = "console-${local.instance_name}"
  description   = "Docker images for the Chameleon console (${local.instance_name})"
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
    component   = "console"
  })

  depends_on = [google_project_service.artifactregistry]
}

# IAM: Cloud Run agent can pull images from the console Artifact Registry repo.
resource "google_artifact_registry_repository_iam_member" "console_cloud_run_artifact_reader" {
  location   = google_artifact_registry_repository.console.location
  repository = google_artifact_registry_repository.console.name
  role       = "roles/artifactregistry.reader"
  member     = google_project_service_identity.run.member
}

# BYOC onboarding: grant a customer project's own runtime service account(s)
# read access (see key_vault.tf's matching grant for the rationale).
resource "google_artifact_registry_repository_iam_member" "console_external_readers" {
  for_each   = toset(var.console_artifact_registry_external_readers)
  location   = google_artifact_registry_repository.console.location
  repository = google_artifact_registry_repository.console.name
  role       = "roles/artifactregistry.reader"
  member     = each.value
}

# IAM: GitHub Actions deploy identity can push console images.
resource "google_artifact_registry_repository_iam_member" "console_deployer_artifact_writer" {
  location   = google_artifact_registry_repository.console.location
  repository = google_artifact_registry_repository.console.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.console_deployer.email}"
}

# IAM: GitHub Actions deploy identity can update Cloud Run and use the runtime SA.
resource "google_project_iam_member" "console_deployer_run_developer" {
  project = var.gcp_project_id
  role    = "roles/run.developer"
  member  = "serviceAccount:${google_service_account.console_deployer.email}"
}

resource "google_service_account_iam_member" "console_deployer_runtime_user" {
  service_account_id = google_service_account.console.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.console_deployer.email}"
}

resource "google_service_account_iam_member" "console_deployer_wif" {
  count = var.enable_workload_identity_federation ? 1 : 0

  service_account_id = google_service_account.console_deployer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github_actions[0].name}/attribute.repository/${var.github_repository_owner}/${var.console_github_repository_name}"
}

# IAM: console can read its own generated password, plus the two Key Vault
# tokens it must forward when calling the Key Vault API (VAULT_API_TOKEN /
# VAULT_REGISTRY_WRITE_TOKEN — see chameleon-console's proxy routes).
resource "google_secret_manager_secret_iam_member" "console_password_reader" {
  secret_id = google_secret_manager_secret.console_password.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.console.email}"
}

resource "google_secret_manager_secret_iam_member" "console_vault_api_key_reader" {
  secret_id = google_secret_manager_secret.vault_api_key.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.console.email}"
}

resource "google_secret_manager_secret_iam_member" "console_pii_registry_write_token_reader" {
  secret_id = google_secret_manager_secret.pii_registry_write_token.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.console.email}"
}

resource "google_cloud_run_v2_service" "console" {
  name                = "${var.app_name}-console-${local.instance_name}"
  location            = var.gcp_region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = var.environment == "prod"

  lifecycle {
    # Same rationale as key_vault's Cloud Run block: image is now
    # Terraform-managed (see that block's comment for why); scaling stays
    # ignored (gcloud writes explicit zeros Terraform treats as drift).
    ignore_changes = [
      scaling,
    ]
  }

  template {
    service_account = google_service_account.console.email

    labels = merge(var.labels, {
      environment = var.environment
      component   = "console"
    })

    scaling {
      # Zero in every environment until there's a real customer -- this was
      # silently costing money 24/7 in prod for no reason (confirmed live:
      # zero real traffic, nothing to keep warm for). Flip back to 1 for
      # prod deliberately once onboarding a real customer, not before.
      min_instance_count = 0
      max_instance_count = var.environment == "prod" ? 10 : 3
    }

    containers {
      image = var.console_image

      ports {
        name           = "http1"
        container_port = 8080
      }

      env {
        name  = "NODE_ENV"
        value = var.environment == "prod" ? "production" : "development"
      }

      # Single source of truth for this instance's tenant id (lib/tenant.ts).
      # Must match the data-pipelines worker's TENANT_ID (pii_ingestor_worker.tf)
      # or the console can trigger a real deletion but never look up the
      # resulting certificate (wrong tenant = 404, masked by the console's own
      # demo-fixture fallback). See local.tenant_id in main.tf.
      env {
        name  = "NEXT_PUBLIC_TENANT_ID"
        value = local.tenant_id
      }

      # Deliberately not NEXT_PUBLIC_-prefixed -- read server-side only
      # (lib/pubsub-ingest.ts) and threaded down as a prop into the
      # client-side declare panel, since this repo's CI never passes env
      # vars at Docker build time and Next.js only inlines NEXT_PUBLIC_*
      # at build time (a runtime-only Cloud Run env var by that name would
      # never actually reach the browser). Empty when the worker isn't
      # enabled (e.g. prod today) -- the declare panel already handles
      # that gracefully, shown as "not configured for this console"
      # instead of a broken URL.
      env {
        name  = "PUBSUB_INGEST_BASE_URL"
        value = var.enable_pii_pubsub_ingest_worker ? google_cloud_run_v2_service.pii_pubsub_ingest_worker[0].uri : ""
      }

      env {
        name  = "VAULT_BASE_URL"
        value = google_cloud_run_v2_service.key_vault.uri
      }

      # See variables.tf's console_service_credential comment -- deliberately
      # a plain value, not a Secret Manager reference, since it's minted by
      # chameleon-onboarding before this project exists at all.
      env {
        name  = "CONSOLE_SERVICE_CREDENTIAL"
        value = var.console_service_credential
      }

      env {
        name = "CONSOLE_PASSWORD"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.console_password.secret_id
            version = "latest"
          }
        }
      }

      # Matches Key Vault's global app-level auth hook (main.ts checks
      # x-api-key OR a Bearer token against this same secret's value).
      env {
        name = "VAULT_API_TOKEN"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.vault_api_key.secret_id
            version = "latest"
          }
        }
      }

      env {
        name = "VAULT_REGISTRY_WRITE_TOKEN"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.pii_registry_write_token.secret_id
            version = "latest"
          }
        }
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
      }
    }
  }

  depends_on = [
    google_secret_manager_secret_iam_member.console_password_reader,
    google_secret_manager_secret_iam_member.console_vault_api_key_reader,
    google_secret_manager_secret_iam_member.console_pii_registry_write_token_reader,
    google_artifact_registry_repository_iam_member.console_cloud_run_artifact_reader,
  ]
}

resource "google_cloud_run_v2_service_iam_member" "console_public_invoker" {
  count = var.console_allow_unauthenticated ? 1 : 0

  project  = var.gcp_project_id
  location = google_cloud_run_v2_service.console.location
  name     = google_cloud_run_v2_service.console.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
