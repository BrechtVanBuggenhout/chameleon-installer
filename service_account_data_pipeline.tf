# Service Account for Data Pipelines
resource "google_service_account" "data_pipeline" {
  account_id   = "${var.app_name}-data-pipeline-${local.instance_short}"
  display_name = "Chameleon Data Pipeline (${local.instance_name})"
  description  = "Service account for Chameleon data ingestion and processing"
}

resource "google_project_iam_member" "data_pipeline_bigquery" {
  project = var.gcp_project_id
  role    = "roles/bigquery.dataEditor"
  member  = "serviceAccount:${google_service_account.data_pipeline.email}"
}

resource "google_project_iam_member" "data_pipeline_bigquery_job" {
  project = var.gcp_project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.data_pipeline.email}"
}

resource "google_project_iam_member" "data_pipeline_warehouse_discovery_bigquery_job" {
  count = local.warehouse_discovery_project_id != var.gcp_project_id ? 1 : 0

  project = local.warehouse_discovery_project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.data_pipeline.email}"
}

resource "google_bigquery_dataset_iam_member" "data_pipeline_warehouse_discovery_metadata_viewer" {
  for_each = var.warehouse_discovery_dataset_ids

  project    = local.warehouse_discovery_project_id
  dataset_id = each.value
  role       = "roles/bigquery.metadataViewer"
  member     = "serviceAccount:${google_service_account.data_pipeline.email}"
}

resource "google_bigquery_dataset_iam_member" "data_pipeline_warehouse_discovery_data_viewer" {
  for_each = var.warehouse_discovery_enable_row_sampling ? var.warehouse_discovery_dataset_ids : toset([])

  project    = local.warehouse_discovery_project_id
  dataset_id = each.value
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${google_service_account.data_pipeline.email}"
}

resource "google_project_iam_member" "data_pipeline_storage" {
  project = var.gcp_project_id
  role    = "roles/storage.objectAdmin"
  member  = "serviceAccount:${google_service_account.data_pipeline.email}"
}

resource "google_bigquery_table_iam_member" "data_pipeline_tenant_map_viewer" {
  project    = var.gcp_project_id
  dataset_id = google_bigquery_dataset.lineage.dataset_id
  table_id   = google_bigquery_table.tenant_access_map.table_id
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${google_service_account.data_pipeline.email}"
}

resource "google_project_iam_member" "data_pipeline_firestore" {
  project = var.gcp_project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.data_pipeline.email}"
}

resource "google_pubsub_topic_iam_member" "data_pipeline_dlq_publisher" {
  topic  = google_pubsub_topic.janitor_dlq.name
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${google_service_account.data_pipeline.email}"
}

resource "google_kms_crypto_key_iam_member" "data_pipeline_kms_viewer" {
  crypto_key_id = google_kms_crypto_key.certificate_signing_key.id
  role          = "roles/cloudkms.viewer"
  member        = "serviceAccount:${google_service_account.data_pipeline.email}"
}

resource "google_kms_crypto_key_iam_member" "data_pipeline_kms" {
  crypto_key_id = google_kms_crypto_key.bigquery_dataset_key.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_service_account.data_pipeline.email}"
}

resource "google_kms_crypto_key_iam_member" "data_pipeline_gcs_kms" {
  crypto_key_id = google_kms_crypto_key.gcs_key.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_service_account.data_pipeline.email}"
}

resource "google_secret_manager_secret_iam_member" "data_pipeline_secret" {
  secret_id = google_secret_manager_secret.cmek_master_key.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.data_pipeline.email}"
}

resource "google_pubsub_topic_iam_member" "data_pipeline_ingestion_publisher" {
  topic  = google_pubsub_topic.pii_ingestion.name
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${google_service_account.data_pipeline.email}"
}
