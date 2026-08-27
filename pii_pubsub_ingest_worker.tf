# Pub/Sub Ingest Cloud Run Worker
#
# A publicly-reachable push endpoint for a CUSTOMER'S OWN Pub/Sub topic,
# declared as a system: 'pubsub' PII resource (see chameleon-key-vault's
# pii-registry.ts). Deliberately a SEPARATE Cloud Run service from
# pii_ingestor_worker, not a new route on it: that service's own routes
# (e.g. /ingest) have no app-level authentication at all -- they rely
# entirely on Cloud Run's platform-level IAM invoker gate
# (google_cloud_run_v2_service_iam_member.pubsub_worker_invoker below in
# pii_ingestor_worker.tf), which applies to the whole service, not
# per-route. Making that service public to add this one endpoint would
# strip every other route's only protection.
#
# This service is public at the Cloud Run platform level instead (granted
# below), and does all real authorization itself: every push's
# Authorization: Bearer <ID token> is cryptographically verified by the
# app (chameleon-data-pipelines/app/pubsub_ingest_main.py), then its
# subject compared against the specific declared resource's own
# pubsubAllowedCallerServiceAccount -- a per-resource value set at declare
# time, not a Terraform variable, since it's dynamic (one per customer
# declaration) and unknown at apply time. Key generation is entirely
# server-side via Key Vault's HTTP API, but reading back an existing
# user's encryption context needs a direct, client-side KMS decrypt (see
# the crypto_key_iam_member grant below) -- this service is public but
# not KMS-blind. Contrast with
# decrypted_views_connection_sa_unique_id (variables.tf), which IS a
# single static Terraform variable, because that endpoint only ever trusts
# one fixed, deploy-time-known caller (BigQuery's own connection SA).
#
# Reuses pii_ingestor_worker_container_image (no separate image build) --
# only the Cloud Run service's own command/args differ, pointing uvicorn at
# app.pubsub_ingest_main:app instead of the default main:app.

resource "google_service_account" "pii_pubsub_ingest_worker" {
  count        = var.enable_pii_pubsub_ingest_worker ? 1 : 0
  account_id   = "${var.app_name}-pubsub-ingest-${local.instance_short}"
  display_name = "Pub/Sub Ingest Cloud Run Worker (${local.instance_name})"
  description  = "Publicly-reachable push endpoint for customer-owned Pub/Sub topics -- deliberately narrower grants than pii_ingestor_worker, since this service is public at the platform level"
}

# Only pii_vault write access -- this service never touches Firestore,
# the GCS landing zone, or any of pii_ingestor_worker's other Pub/Sub
# topics directly. Key CREATION goes entirely through Key Vault's own HTTP
# API (VAULT_API_TOKEN below) -- but reading an existing encryption
# context does not: VaultClient.get_encryption_context() (vault_client.py)
# unwraps the returned DEK with a direct client-side KMS decrypt call
# (self.kms_client.decrypt(...)), same as every other VaultClient caller
# in this codebase. Confirmed live in the dev project: without the
# grant below, every real push failed with
# "cloudkms.cryptoKeyVersions.useToDecrypt" IAM_PERMISSION_DENIED, since
# this is a genuinely different call path than the HTTP-only one this
# comment originally (incorrectly) assumed.
resource "google_bigquery_dataset_iam_member" "pii_pubsub_ingest_worker_bq_editor" {
  count      = var.enable_pii_pubsub_ingest_worker ? 1 : 0
  project    = var.gcp_project_id
  dataset_id = google_bigquery_dataset.chameleon.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.pii_pubsub_ingest_worker[0].email}"
}

resource "google_project_iam_member" "pii_pubsub_ingest_worker_bq_job_user" {
  count   = var.enable_pii_pubsub_ingest_worker ? 1 : 0
  project = var.gcp_project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.pii_pubsub_ingest_worker[0].email}"
}

# Decrypt-only -- narrower than pii_ingestor_worker's own
# roles/cloudkms.cryptoKeyEncrypterDecrypter grant (ingestor_kms_encrypter_decrypter
# in pii_ingestor_worker.tf), since this service only ever reads back an
# existing user's wrapped DEK via VaultClient, never wraps a new one itself
# (key creation is entirely server-side, via Key Vault's HTTP API).
resource "google_kms_crypto_key_iam_member" "pii_pubsub_ingest_worker_kms_decrypter" {
  count         = var.enable_pii_pubsub_ingest_worker ? 1 : 0
  crypto_key_id = google_kms_crypto_key.key_vault_key.id
  role          = "roles/cloudkms.cryptoKeyDecrypter"
  member        = "serviceAccount:${google_service_account.pii_pubsub_ingest_worker[0].email}"
}

# Authenticates this service's VaultClient to Key Vault's app-level
# VAULT_API_KEY hook -- same shared secret pii_ingestor_worker and the
# console already use.
resource "google_secret_manager_secret_iam_member" "pii_pubsub_ingest_worker_vault_api_key" {
  count     = var.enable_pii_pubsub_ingest_worker ? 1 : 0
  secret_id = google_secret_manager_secret.vault_api_key.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.pii_pubsub_ingest_worker[0].email}"
}

resource "google_cloud_run_v2_service" "pii_pubsub_ingest_worker" {
  count    = var.enable_pii_pubsub_ingest_worker ? 1 : 0
  name     = "${var.app_name}-pubsub-ingest-worker-${local.instance_name}"
  location = var.gcp_region

  # Unlike key_vault/console (deletion_protection = var.environment == "prod"
  # -- they hold real request state worth protecting), this service is a
  # thin, stateless push handler: all real state lives in pii_vault/
  # Firestore, never in the Cloud Run service itself, so a destroy+recreate
  # loses nothing. Confirmed this matters live: without an explicit value
  # here, the provider's own default (true) blocked recovering from a
  # crashed first revision in the prod project with "cannot destroy
  # service without setting deletion_protection=false".
  deletion_protection = false

  template {
    service_account = google_service_account.pii_pubsub_ingest_worker[0].email
    # Cloud Run's default (300s) comfortably covers one push message's
    # processing (a handful of Vault round-trips + one streaming insert) --
    # unlike pii_ingestor_worker's 3600s, there's no long-running batch work
    # here, so the shorter default is left alone deliberately: a genuinely
    # stuck request should time out and let Pub/Sub redeliver, not tie up
    # an instance for an hour.
    max_instance_request_concurrency = 4
    containers {
      image   = var.pii_ingestor_worker_container_image
      command = ["uvicorn"]
      args    = ["app.pubsub_ingest_main:app", "--host", "0.0.0.0", "--port", "8080"]
      resources {
        limits = {
          cpu    = "1000m"
          memory = "512Mi"
        }
      }
      env {
        name  = "GOOGLE_CLOUD_PROJECT"
        value = var.gcp_project_id
      }
      env {
        name  = "BIGQUERY_DATASET"
        value = google_bigquery_dataset.chameleon.dataset_id
      }
      env {
        name  = "TENANT_ID"
        value = local.tenant_id
      }
      env {
        name  = "VAULT_BASE_URL"
        value = google_cloud_run_v2_service.key_vault.uri
      }
      env {
        name = "VAULT_API_TOKEN"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.vault_api_key.secret_id
            version = "latest"
          }
        }
      }
      # This image's app/config.py Settings model requires every one of
      # these fields regardless of which entrypoint actually runs (see
      # requirements.txt/config.py) -- none are meaningful to this
      # service, but must be present for the shared image to boot.
      # Non-secret placeholders; this service never reads them.
      env {
        name  = "JANITOR_DLQ_TOPIC"
        value = google_pubsub_topic.janitor_dlq.name
      }
      env {
        name  = "PII_TOPIC_ID"
        value = google_pubsub_topic.pii_ingestion.id
      }
      env {
        name  = "LINEAGE_TOPIC_ID"
        value = google_pubsub_topic.pii_lineage_events.id
      }
      env {
        name  = "PII_VAULT_SYNC_CHUNK_TOPIC_ID"
        value = google_pubsub_topic.pii_vault_sync_chunks.id
      }
      env {
        name  = "LANDING_ZONE_BUCKET"
        value = google_storage_bucket.landing_zone.name
      }
      env {
        name  = "KMS_KEY_PATH"
        value = "projects/${var.gcp_project_id}/locations/${var.kms_region}/keyRings/${google_kms_key_ring.regional.name}/cryptoKeys/${google_kms_crypto_key.key_vault_key.name}"
      }
      env {
        name  = "KMS_SIGNING_PROJECT_ID"
        value = var.gcp_project_id
      }
      env {
        name  = "KMS_SIGNING_KEY_RING"
        value = google_kms_key_ring.signing.name
      }
      env {
        name  = "KMS_SIGNING_KEY_NAME"
        value = google_kms_crypto_key.certificate_signing_key.name
      }
    }
    scaling {
      min_instance_count = 0
      max_instance_count = var.pii_pubsub_ingest_worker_max_instances
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  labels = merge(var.labels, {
    component = "pubsub-ingest-worker"
  })

  lifecycle {
    ignore_changes = [
      scaling,
    ]
  }

  depends_on = [
    google_secret_manager_secret_iam_member.pii_pubsub_ingest_worker_vault_api_key,
  ]
}

# The whole point: this service is reachable by ANY customer's Pub/Sub push
# subscription, not a single deploy-time-known caller -- there's no fixed
# service account to grant run.invoker to ahead of time the way
# pii_ingestor_worker's own subscriptions do. Real authorization is
# entirely app-level (see this file's own top-of-file docs); Cloud Run's
# platform-level gate is deliberately left open for this one service.
resource "google_cloud_run_v2_service_iam_member" "pii_pubsub_ingest_worker_public_invoker" {
  count    = var.enable_pii_pubsub_ingest_worker ? 1 : 0
  location = google_cloud_run_v2_service.pii_pubsub_ingest_worker[0].location
  name     = google_cloud_run_v2_service.pii_pubsub_ingest_worker[0].name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

output "pii_pubsub_ingest_worker_url" {
  description = "Base URL of the Pub/Sub Ingest worker. A customer declaring a system: 'pubsub' resource points their own push subscription at {this}/pubsub-ingest/{urlencoded resourceId}."
  value       = var.enable_pii_pubsub_ingest_worker ? google_cloud_run_v2_service.pii_pubsub_ingest_worker[0].uri : null
}
