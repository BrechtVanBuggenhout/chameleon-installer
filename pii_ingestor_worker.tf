# Service Account for PII Ingestor Worker
resource "google_service_account" "pii_ingestor_worker" {
  account_id   = "${var.app_name}-pii-ingestor-${local.instance_short}"
  display_name = "PII Ingestor Cloud Run Worker (${local.instance_name})"
  description  = "Handles sequential writes to Firestore and BigQuery"
}

resource "google_project_iam_member" "pii_ingestor_worker_bq_job_user" {
  count   = var.enable_pii_ingestor_worker ? 1 : 0
  project = var.gcp_project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.pii_ingestor_worker.email}"
}

resource "google_bigquery_dataset_iam_member" "pii_ingestor_worker_bq_editor" {
  count      = var.enable_pii_ingestor_worker ? 1 : 0
  project    = var.gcp_project_id
  dataset_id = google_bigquery_dataset.chameleon.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.pii_ingestor_worker.email}"
}

# IAM: Worker can read the shared Vault API key so its VaultClient can pass the
# Key Vault's app-level auth (VAULT_API_TOKEN env below).
resource "google_secret_manager_secret_iam_member" "pii_ingestor_worker_vault_api_key" {
  count     = var.enable_pii_ingestor_worker ? 1 : 0
  secret_id = google_secret_manager_secret.vault_api_key.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.pii_ingestor_worker.email}"
}

resource "google_project_iam_member" "ingestor_firestore" {
  project = var.gcp_project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.pii_ingestor_worker.email}"
}

resource "google_project_iam_member" "ingestor_bigquery" {
  project = var.gcp_project_id
  role    = "roles/bigquery.dataEditor"
  member  = "serviceAccount:${google_service_account.pii_ingestor_worker.email}"
}

resource "google_storage_bucket_iam_member" "ingestor_landing_zone" {
  bucket = google_storage_bucket.landing_zone.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.pii_ingestor_worker.email}"
}

resource "google_kms_crypto_key_iam_member" "ingestor_kms_encrypter_decrypter" {
  crypto_key_id = google_kms_crypto_key.key_vault_key.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_service_account.pii_ingestor_worker.email}"
}

resource "google_pubsub_topic_iam_member" "ingestor_pii_topic_publisher" {
  project = var.gcp_project_id
  topic   = google_pubsub_topic.pii_ingestion.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.pii_ingestor_worker.email}"
}

resource "google_pubsub_topic_iam_member" "ingestor_lineage_topic_publisher" {
  project = var.gcp_project_id
  topic   = google_pubsub_topic.pii_lineage_events.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.pii_ingestor_worker.email}"
}

resource "google_pubsub_topic_iam_member" "ingestor_dlq_topic_publisher" {
  project = var.gcp_project_id
  topic   = google_pubsub_topic.janitor_dlq.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.pii_ingestor_worker.email}"
}

# Cloud Run PII Ingestor Worker Service
resource "google_cloud_run_v2_service" "pii_ingestor_worker" {
  count    = var.enable_pii_ingestor_worker ? 1 : 0
  name     = "${var.app_name}-pii-ingestor-worker-${local.instance_name}"
  location = var.gcp_region

  template {
    service_account = google_service_account.pii_ingestor_worker.email
    containers {
      image = var.pii_ingestor_worker_container_image
      resources {
        limits = {
          cpu = "1000m"
          # Went 512Mi -> 1Gi -> 2Gi. Each OOM was only a modest amount over
          # whatever the current limit was (18MiB, then 1MiB, then 49MiB
          # over) even after the sync job was fixed to process in bounded
          # chunks (see pii_vault_sync.py CHUNK_SIZE) -- that pattern says
          # this service's baseline footprint (FastAPI + pandas + every
          # google-cloud-* client loaded at startup) sits close to whatever
          # limit is set, and real request work tips it over regardless of
          # chunk size. Giving real headroom above that baseline this time
          # instead of doubling again and hoping.
          memory = "2Gi"
        }
      }
      env {
        name  = "GOOGLE_CLOUD_PROJECT"
        value = var.gcp_project_id
      }
      env {
        name  = "STAGING_DATASET"
        value = google_bigquery_dataset.chameleon.dataset_id
      }
      env {
        name  = "STAGING_DATASET_ID"
        value = google_bigquery_dataset.chameleon.dataset_id
      }
      env {
        name  = "STAGING_TABLE"
        value = google_bigquery_table.raw_users.table_id
      }
      env {
        name  = "VAULT_BASE_URL"
        value = google_cloud_run_v2_service.key_vault.uri
      }
      env {
        name  = "KMS_KEY_PATH"
        value = "projects/${var.gcp_project_id}/locations/${var.kms_region}/keyRings/${google_kms_key_ring.regional.name}/cryptoKeys/${google_kms_crypto_key.key_vault_key.name}"
      }
      env {
        name  = "LANDING_ZONE_BUCKET"
        value = google_storage_bucket.landing_zone.name
      }
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
        name  = "TENANT_MODE"
        value = "MULTI"
      }
      env {
        name  = "TENANT_ID"
        value = local.tenant_id
      }
      env {
        name  = "BIGQUERY_DATASET"
        value = google_bigquery_dataset.chameleon.dataset_id
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
      env {
        name  = "KMS_SIGNING_KEY_VERSION"
        value = var.key_vault_signing_key_version
      }
      # Authenticates the worker's VaultClient to the Key Vault's app-level
      # VAULT_API_KEY hook (same shared secret the console uses).
      env {
        name = "VAULT_API_TOKEN"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.vault_api_key.secret_id
            version = "latest"
          }
        }
      }
      # Warehouse metadata discovery scope. The app's config.py defaults point at the
      # DEV project, so without these the prod worker crawls dev and 403s.
      env {
        name  = "WAREHOUSE_DISCOVERY_PROJECT_ID"
        value = local.warehouse_discovery_project_id
      }
      env {
        name  = "WAREHOUSE_DISCOVERY_DATASETS"
        value = google_bigquery_dataset.chameleon.dataset_id
      }

      # Ingestion write-path warehouse selection. Vars/secret container
      # declared in snowflake.tf; the env wiring has to live in this resource
      # block. Omitted entirely when still "bigquery" (the default) so this
      # is a zero-diff no-op for every existing deployment -- the app's own
      # config.py already defaults WAREHOUSE_TYPE to "bigquery".
      dynamic "env" {
        for_each = var.pii_warehouse_type != "bigquery" ? [1] : []
        content {
          name  = "WAREHOUSE_TYPE"
          value = var.pii_warehouse_type
        }
      }

      dynamic "env" {
        for_each = var.pii_warehouse_type == "snowflake" ? [1] : []
        content {
          name  = "PII_INGESTOR_SNOWFLAKE_ACCOUNT"
          value = var.pii_ingestor_snowflake_account
        }
      }

      dynamic "env" {
        for_each = var.pii_warehouse_type == "snowflake" ? [1] : []
        content {
          name  = "PII_INGESTOR_SNOWFLAKE_USER"
          value = var.pii_ingestor_snowflake_user
        }
      }

      dynamic "env" {
        for_each = var.pii_warehouse_type == "snowflake" ? [1] : []
        content {
          name  = "PII_INGESTOR_SNOWFLAKE_ROLE"
          value = var.pii_ingestor_snowflake_role
        }
      }

      dynamic "env" {
        for_each = var.pii_warehouse_type == "snowflake" ? [1] : []
        content {
          name  = "PII_INGESTOR_SNOWFLAKE_WAREHOUSE"
          value = var.pii_ingestor_snowflake_warehouse
        }
      }

      dynamic "env" {
        for_each = var.pii_warehouse_type == "snowflake" ? [1] : []
        content {
          name  = "PII_INGESTOR_SNOWFLAKE_DATABASE"
          value = var.pii_ingestor_snowflake_database
        }
      }

      dynamic "env" {
        for_each = var.pii_warehouse_type == "snowflake" ? [1] : []
        content {
          name  = "PII_INGESTOR_SNOWFLAKE_SCHEMA"
          value = var.pii_ingestor_snowflake_schema
        }
      }

      dynamic "env" {
        for_each = var.pii_warehouse_type == "snowflake" ? [1] : []
        content {
          name = "PII_INGESTOR_SNOWFLAKE_PASSWORD"
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.pii_ingestor_snowflake_password[0].secret_id
              version = "latest"
            }
          }
        }
      }
    }
    scaling {
      min_instance_count = 1
      max_instance_count = var.pii_ingestor_worker_max_instances
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  labels = merge(var.labels, {
    component = "ingestion-worker"
  })

  lifecycle {
    ignore_changes = [
      template[0].containers[0].image,
      scaling,
    ]
  }

  # Cloud Run rejects the revision if the runtime SA cannot read referenced secrets.
  depends_on = [
    google_secret_manager_secret_iam_member.pii_ingestor_worker_vault_api_key,
    google_secret_manager_secret_iam_member.pii_ingestor_worker_snowflake_secret,
    google_secret_manager_secret_version.pii_ingestor_snowflake_password_version,
  ]
}

# Updated: Pivot from Direct BQ to Cloud Run Worker Push
resource "google_pubsub_subscription" "pii_ingestion_worker_push" {
  name  = "pii-ingestion-worker-sub-${local.instance_name}"
  topic = google_pubsub_topic.pii_ingestion.name

  push_config {
    push_endpoint = var.enable_pii_ingestor_worker ? "${google_cloud_run_v2_service.pii_ingestor_worker[0].uri}/ingest" : "https://placeholder-url"

    oidc_token {
      service_account_email = google_service_account.data_pipeline.email
    }
  }

  ack_deadline_seconds = 60
}

# IAM: Allow Pub/Sub to invoke the Ingestor Worker
resource "google_cloud_run_v2_service_iam_member" "pubsub_worker_invoker" {
  count    = var.enable_pii_ingestor_worker ? 1 : 0
  location = google_cloud_run_v2_service.pii_ingestor_worker[0].location
  name     = google_cloud_run_v2_service.pii_ingestor_worker[0].name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.data_pipeline.email}"
}

# Scheduled warehouse metadata crawl: periodically flags undeclared / drifted PII
# tables (e.g. Fivetran-created) and emits WAREHOUSE_METADATA_DISCOVERED lineage events,
# which surface in the Console's "declare undeclared table" workflow. Reuses the
# data_pipeline SA, which already holds run.invoker on the worker (pubsub_worker_invoker).
resource "google_cloud_scheduler_job" "warehouse_metadata_crawl" {
  count       = var.enable_pii_ingestor_worker ? 1 : 0
  name        = "${var.app_name}-warehouse-crawl-${local.instance_name}"
  description = "Periodic BigQuery warehouse metadata crawl for undeclared/drifted PII discovery"
  schedule    = var.warehouse_crawl_schedule
  region      = var.gcp_region
  time_zone   = "Etc/UTC"

  http_target {
    http_method = "POST"
    uri         = "${google_cloud_run_v2_service.pii_ingestor_worker[0].uri}/api/v1/warehouse-crawl"

    oidc_token {
      service_account_email = google_service_account.data_pipeline.email
      audience              = google_cloud_run_v2_service.pii_ingestor_worker[0].uri
    }
  }

  depends_on = [
    google_project_service.cloudscheduler,
    google_cloud_run_v2_service_iam_member.pubsub_worker_invoker
  ]
}
