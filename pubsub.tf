# Pub/Sub Schemas for Avro transition
resource "google_pubsub_schema" "user_ingestion" {
  name = "user-ingestion-schema-${local.instance_name}"
  type = "AVRO"
  definition = jsonencode({
    type = "record"
    name = "UserIngestion"
    fields = [
      { name = "tenant_id", type = ["null", "string"], default = null },
      { name = "user_id", type = "string" },
      { name = "email_token", type = "string" },
      { name = "encryption_version", type = "string" },
      { name = "key_id", type = ["null", "string"], default = null },
      { name = "encrypted_pii", type = "bytes" },
      { name = "data_hash", type = "string" },
      { name = "operation_id", type = "string" },
      { name = "ingested_at", type = "string" },
      { name = "source_system", type = "string" }
    ]
  })

  depends_on = [google_project_service.pubsub]
}

resource "google_pubsub_schema" "lineage_event" {
  name = "lineage-event-schema-${local.instance_name}"
  type = "AVRO"
  definition = jsonencode({
    type = "record"
    name = "LineageEvent"
    fields = [
      { name = "event_id", type = "string" },
      { name = "tenant_id", type = ["null", "string"], default = null },
      { name = "user_id", type = "string" },
      { name = "source", type = "string" },
      { name = "destination", type = "string" },
      { name = "timestamp", type = "string" },
      { name = "context", type = "string" }
    ]
  })

  depends_on = [google_project_service.pubsub]
}

resource "google_pubsub_schema" "lineage_event_v2" {
  name = "lineage-event-schema-v2-${local.instance_name}"
  type = "AVRO"
  definition = jsonencode({
    type = "record"
    name = "LineageEvent"
    fields = [
      { name = "event_id", type = "string" },
      { name = "tenant_id", type = ["null", "string"], default = null },
      { name = "user_id", type = "string" },
      { name = "source", type = "string" },
      { name = "destination", type = "string" },
      {
        name = "timestamp",
        type = {
          type        = "long"
          logicalType = "timestamp-micros"
        }
      },
      { name = "context", type = "string" }
    ]
  })

  depends_on = [google_project_service.pubsub]
}

# Pub/Sub - Asynchronous Ingestion Stream
resource "google_pubsub_topic" "pii_ingestion" {
  name = "pii-ingestion-stream-${local.instance_name}"

  schema_settings {
    schema   = google_pubsub_schema.user_ingestion.id
    encoding = "BINARY"
  }

  labels = merge(var.labels, {
    environment = "data-pipeline"
    purpose     = "async-ingestion"
  })
}

# Pub/Sub - Lineage Event Stream
resource "google_pubsub_topic" "pii_lineage_events" {
  name = "pii-lineage-events-stream-${local.instance_name}"

  schema_settings {
    schema   = google_pubsub_schema.lineage_event_v2.id
    encoding = "BINARY"
  }

  labels = merge(var.labels, {
    environment = var.environment
    component   = "lineage-engine"
    purpose     = "event-driven-lineage"
  })
}

resource "google_pubsub_subscription" "lineage_events_bq_push" {
  name  = "lineage-events-bq-sub-${local.instance_name}"
  topic = google_pubsub_topic.pii_lineage_events.name

  bigquery_config {
    table               = "${var.gcp_project_id}.${google_bigquery_dataset.lineage.dataset_id}.${google_bigquery_table.lineage_events.table_id}"
    use_topic_schema    = true
    write_metadata      = false
    drop_unknown_fields = true
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.lineage_bq_dlq.id
    max_delivery_attempts = 5
  }

  depends_on = [
    google_project_iam_member.pubsub_bq_editor,
    google_pubsub_topic_iam_member.pubsub_lineage_bq_dlq_publisher
  ]
}

# Pub/Sub - Lineage BigQuery Dead Letter Queue
resource "google_pubsub_topic" "lineage_bq_dlq" {
  name = "lineage-bq-dead-letter-queue-${local.instance_name}"

  labels = merge(var.labels, {
    environment = var.environment
    component   = "lineage-engine"
    purpose     = "bigquery-dead-letter-queue"
  })
}

resource "google_pubsub_topic_iam_member" "pubsub_lineage_bq_dlq_publisher" {
  topic  = google_pubsub_topic.lineage_bq_dlq.name
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

# Pub/Sub Subscription - Lineage DLQ to BigQuery
resource "google_pubsub_subscription" "lineage_dlq_bq" {
  name  = "lineage-dlq-bq-sub-${local.instance_name}"
  topic = google_pubsub_topic.lineage_bq_dlq.name

  bigquery_config {
    table          = "${var.gcp_project_id}.${google_bigquery_dataset.lineage.dataset_id}.${google_bigquery_table.lineage_failed_events.table_id}"
    write_metadata = true
  }

  depends_on = [google_project_iam_member.pubsub_bq_editor]
}

# Pub/Sub - Janitor Dead Letter Queue
resource "google_pubsub_topic" "janitor_dlq" {
  name = "janitor-dead-letter-queue-${local.instance_name}"

  labels = merge(var.labels, {
    environment = var.environment
    component   = "key-vault"
    purpose     = "dead-letter-queue"
  })
}

# Pub/Sub Subscription - BigQuery Push for DLQ
resource "google_pubsub_subscription" "janitor_dlq_bq" {
  name  = "janitor-dlq-bq-sub-${local.instance_name}"
  topic = google_pubsub_topic.janitor_dlq.name

  bigquery_config {
    table               = "${var.gcp_project_id}.${google_bigquery_dataset.lineage.dataset_id}.${google_bigquery_table.janitor_failed_wipes.table_id}"
    use_topic_schema    = false # We define a standard BQ schema to capture raw data
    write_metadata      = true
    drop_unknown_fields = true
  }

  depends_on = [google_project_iam_member.pubsub_bq_editor]
}

# Pub/Sub - PII Vault Sync Chunk Fan-Out
#
# Fan-out target for PiiVaultSyncJob.enumerate_resource: one message per
# chunk of user IDs, consumed by the worker's /api/v1/pii-vault-sync-chunk
# via the push subscription below. This is what makes the trigger itself
# (POST /api/v1/pii-vault-sync, called directly by Cloud Scheduler and by
# Key Vault's Sync Now) stay fast regardless of table size -- the actual
# encrypt-diff-insert work happens later, per chunk, off of this topic,
# not synchronously inside the trigger call. See pii_vault_sync.py's
# module docstring for the real problem this replaced: a first-time
# backfill of Immoscoop's ~530k users completed correctly server-side as
# one synchronous call, but the client that triggered it gave up waiting
# long before the job actually finished.
resource "google_pubsub_topic" "pii_vault_sync_chunks" {
  name = "pii-vault-sync-chunks-${local.instance_name}"

  labels = merge(var.labels, {
    environment = "data-pipeline"
    purpose     = "pii-vault-sync-chunk-fan-out"
  })
}

# IAM: Allow Pub/Sub to write to BigQuery
resource "google_project_iam_member" "pubsub_bq_editor" {
  project = var.gcp_project_id
  role    = "roles/bigquery.dataEditor"
  member  = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

resource "google_project_iam_member" "pubsub_bq_metadata" {
  project = var.gcp_project_id
  role    = "roles/bigquery.metadataViewer"
  member  = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}
