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

# IAM: Worker can read the PII registry write token (separate secret from
# vault_api_key above -- see PII_REGISTRY_WRITE_TOKEN env below).
resource "google_secret_manager_secret_iam_member" "pii_ingestor_worker_pii_registry_write_token" {
  count     = var.enable_pii_ingestor_worker ? 1 : 0
  secret_id = google_secret_manager_secret.pii_registry_write_token.id
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

# IAM: the worker publishes its own pii_vault_sync_chunks messages
# (PiiVaultSyncJob.enumerate_resource), then consumes them right back via
# the push subscription below -- same service, both ends.
resource "google_pubsub_topic_iam_member" "ingestor_pii_vault_sync_chunk_publisher" {
  project = var.gcp_project_id
  topic   = google_pubsub_topic.pii_vault_sync_chunks.name
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
    # Cloud Run's default (300s) isn't enough for a real first-time PII
    # vault sync: a customer's existing table can have hundreds of
    # thousands of rows, chunked at CHUNK_SIZE=100 -- each chunk is a real
    # network round trip (key creation, encryption context fetch, a
    # BigQuery load job), so even a modest per-chunk latency adds up to
    # far more than 5 minutes for a large table. Set to Cloud Run's actual
    # maximum so each invocation does as much useful work as possible.
    # Safe regardless of table size or how long a single run takes: the
    # sync is idempotent (only ever processes users not yet in the vault),
    # so getting cut off mid-run just means the next invocation --
    # manual, or tomorrow's scheduled one -- picks up exactly where this
    # one left off, no double-processing or lost work either way.
    timeout = "3600s"
    # Never explicitly set before -- Cloud Run v2 defaults to 80 concurrent
    # requests per instance. enumerate_resource() publishes every chunk for
    # a resource back-to-back with no throttling (~5,300 messages for
    # Immoscoop's ~530k users at CHUNK_SIZE=100), so Pub/Sub's push
    # subscription was delivering a burst of chunks fast enough for a
    # single instance to end up running dozens of process_chunk() calls at
    # once -- each holding its own BigQuery query result set, a BigQuery
    # load job, and a Vault round-trip simultaneously. That's the real
    # cause of both symptoms this service has actually hit: the OOMs
    # despite three memory bumps (512Mi -> 1Gi -> 2Gi -> see below) were
    # concurrent per-request memory piling up on top of this service's
    # already-heavy baseline, not any single request growing; and the
    # BigQuery 429s were dozens of concurrent load jobs/queries hitting
    # pii_vault's per-table write-rate limit at once. Capping concurrency
    # bounds both -- max_instance_count (below) still provides real
    # throughput via more instances instead of more per-instance load.
    max_instance_request_concurrency = 4
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
        name  = "PII_VAULT_SYNC_CHUNK_TOPIC_ID"
        value = google_pubsub_topic.pii_vault_sync_chunks.id
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
      # Separate from VAULT_API_TOKEN above -- gates the PII registry's own
      # write routes (mark-synced, mark-sync-attempted, sync-runs/*), which
      # requireWriteAuth checks independently of the general VAULT_API_KEY
      # hook (see chameleon-key-vault's pii-registry.ts/sync-runs.ts). The
      # worker's VaultClient previously only ever sent VAULT_API_TOKEN on
      # every call, which Key Vault's requireWriteAuth doesn't accept -- every
      # one of these calls had been silently 401ing.
      env {
        name = "PII_REGISTRY_WRITE_TOKEN"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.pii_registry_write_token.secret_id
            version = "latest"
          }
        }
      }
      # Powers the update-availability check (source_staleness.py) --
      # compared against chameleon-installer's latest GitHub Release. Null
      # (omitted entirely) on deployments that predate versioned images;
      # the check reports "unknown" rather than a false "stale" for those.
      dynamic "env" {
        for_each = var.platform_version != null ? [1] : []
        content {
          name  = "PLATFORM_VERSION"
          value = var.platform_version
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
      # Zero in every environment until there's a real customer -- this was
      # silently costing money 24/7 in prod for no reason (confirmed live:
      # zero real traffic, nothing to keep warm for). Previously kept prod
      # at 1 specifically to avoid a cold start blowing this service's
      # Pub/Sub push subscription's ack deadline (triggering a spurious
      # redelivery) -- that's a real concern, but only once real traffic
      # exists to actually hit it. Flip back to 1 for prod deliberately
      # once onboarding a real customer, not before.
      min_instance_count = 0
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
    # Same rationale as key_vault's Cloud Run block: image is now
    # Terraform-managed (see that block's comment for why); scaling stays
    # ignored (gcloud writes explicit zeros Terraform treats as drift).
    ignore_changes = [
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

# Push subscription for pii_vault_sync_chunks -- each message is one chunk
# (PiiVaultSyncJob.CHUNK_SIZE user IDs) of one declared resource, published
# by /api/v1/pii-vault-sync's enumeration step. 300s (well under Pub/Sub's
# 600s push ceiling) gives real headroom over a chunk's expected processing
# time while still leaving margin before Pub/Sub would consider a slow
# chunk un-acked and redeliver it.
resource "google_pubsub_subscription" "pii_vault_sync_chunk_worker_push" {
  name  = "pii-vault-sync-chunk-worker-sub-${local.instance_name}"
  topic = google_pubsub_topic.pii_vault_sync_chunks.name

  push_config {
    push_endpoint = var.enable_pii_ingestor_worker ? "${google_cloud_run_v2_service.pii_ingestor_worker[0].uri}/api/v1/pii-vault-sync-chunk" : "https://placeholder-url"

    oidc_token {
      service_account_email = google_service_account.data_pipeline.email
    }
  }

  ack_deadline_seconds = 300

  # Without this, a 500 (process_chunk's generic error handler, including a
  # BigQuery 429) triggers Pub/Sub's default immediate redelivery -- hammering
  # the same rate-limited pii_vault table again right away instead of backing
  # off. Complements process_chunk's own in-process retry (pii_vault_sync.py)
  # as a net for whatever that doesn't catch, e.g. an instance recycling
  # mid-request.
  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }
}

# IAM: Allow Pub/Sub to invoke the Ingestor Worker
resource "google_cloud_run_v2_service_iam_member" "pubsub_worker_invoker" {
  count    = var.enable_pii_ingestor_worker ? 1 : 0
  location = google_cloud_run_v2_service.pii_ingestor_worker[0].location
  name     = google_cloud_run_v2_service.pii_ingestor_worker[0].name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.data_pipeline.email}"
}

# IAM: Allow Key Vault to invoke the Ingestor Worker's on-demand sync route
# (POST /pii-registry/sync-now) -- same role Pub/Sub already holds above, so
# the console's "Sync Now" button can trigger the same job the scheduler
# fires daily, without waiting for the next scheduled run.
resource "google_cloud_run_v2_service_iam_member" "key_vault_worker_invoker" {
  count    = var.enable_pii_ingestor_worker ? 1 : 0
  location = google_cloud_run_v2_service.pii_ingestor_worker[0].location
  name     = google_cloud_run_v2_service.pii_ingestor_worker[0].name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.key_vault.email}"
}

# IAM: Allow Key Vault to read the worker's Cloud Run Admin API metadata
# (GetService) -- run.invoker above only grants the ability to call the
# service, not to read its .uri. Key Vault needs to resolve that URL itself
# at runtime (see PII_INGESTOR_WORKER_SERVICE_NAME/_REGION in key_vault.tf),
# since referencing this resource's .uri directly from key_vault.tf would be
# a Terraform dependency cycle -- this service already depends on Key
# Vault's own .uri for VAULT_BASE_URL below.
resource "google_cloud_run_v2_service_iam_member" "key_vault_worker_viewer" {
  count    = var.enable_pii_ingestor_worker ? 1 : 0
  location = google_cloud_run_v2_service.pii_ingestor_worker[0].location
  name     = google_cloud_run_v2_service.pii_ingestor_worker[0].name
  role     = "roles/run.viewer"
  member   = "serviceAccount:${google_service_account.key_vault.email}"
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

# IAM: Worker can read the source SHAs scripts/build-own-images.sh recorded
# at build time, to compare against the public repos' current HEAD (see
# enable_source_staleness_check in variables.tf). Not a Terraform-managed
# secret -- the script owns this one's full lifecycle -- so this references
# it by literal ID rather than google_secret_manager_secret.X.id like every
# other grant in this file; gated behind the var since the secret won't
# exist yet for a customer who hasn't run that script.
resource "google_secret_manager_secret_iam_member" "pii_ingestor_worker_source_shas" {
  count     = var.enable_source_staleness_check ? 1 : 0
  secret_id = "chameleon-source-shas"
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.pii_ingestor_worker.email}"
}

# Scheduled source-staleness check: compares scripts/build-own-images.sh's
# recorded source SHAs against the public repos' current HEAD and logs a
# warning (this project's own Cloud Logging only, never sent to Chameleon)
# if this deployment has drifted. Same OIDC pattern as warehouse_metadata_crawl.
resource "google_cloud_scheduler_job" "source_staleness_check" {
  count       = var.enable_source_staleness_check ? 1 : 0
  name        = "${var.app_name}-source-staleness-${local.instance_name}"
  description = "Weekly check: are this instance's build-own-images.sh source SHAs behind the public repos' current HEAD? Logs only, never leaves this project."
  schedule    = var.source_staleness_check_schedule
  region      = var.gcp_region
  time_zone   = "Etc/UTC"

  http_target {
    http_method = "POST"
    uri         = "${google_cloud_run_v2_service.pii_ingestor_worker[0].uri}/api/v1/source-staleness-check"

    oidc_token {
      service_account_email = google_service_account.data_pipeline.email
      audience              = google_cloud_run_v2_service.pii_ingestor_worker[0].uri
    }
  }

  depends_on = [
    google_project_service.cloudscheduler,
    google_cloud_run_v2_service_iam_member.pubsub_worker_invoker,
    google_secret_manager_secret_iam_member.pii_ingestor_worker_source_shas,
  ]
}

# Scheduled dbt-discovery publish: the chameleon_pii dbt package's
# pii_discovery findings only reached the console when someone remembered to
# run scripts/publish_dbt_pii_discovery.py by hand after a dbt build -- the
# endpoint always existed, nothing ever called it on a schedule. Same
# gating/SA/OIDC pattern as warehouse_metadata_crawl above (no separate
# enable var -- both are "does this deployment run the ingestor worker at
# all" questions, not independent opt-ins). No-op server-side if
# DBT_PII_DISCOVERY_DATASETS isn't set, same as warehouse discovery.
resource "google_cloud_scheduler_job" "dbt_pii_discovery" {
  count       = var.enable_pii_ingestor_worker ? 1 : 0
  name        = "${var.app_name}-dbt-pii-discovery-${local.instance_name}"
  description = "Publish the chameleon_pii dbt package's undeclared-PII discovery findings into the console's live discovery feed"
  schedule    = var.dbt_pii_discovery_schedule
  region      = var.gcp_region
  time_zone   = "Etc/UTC"

  http_target {
    http_method = "POST"
    uri         = "${google_cloud_run_v2_service.pii_ingestor_worker[0].uri}/api/v1/publish-dbt-pii-discovery"

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
