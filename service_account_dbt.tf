# Service Account for dbt
resource "google_service_account" "dbt" {
  account_id   = "${var.app_name}-dbt-${local.instance_short}"
  display_name = "Chameleon dbt (${local.instance_name})"
  description  = "Service account for dbt BigQuery transformations"
}

resource "google_project_iam_member" "dbt_bigquery_job" {
  project = var.gcp_project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.dbt.email}"
}

resource "google_bigquery_dataset_iam_member" "dbt_chameleon_editor" {
  project    = var.gcp_project_id
  dataset_id = google_bigquery_dataset.chameleon.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.dbt.email}"
}

resource "google_bigquery_dataset_iam_member" "dbt_lineage_viewer" {
  project    = var.gcp_project_id
  dataset_id = google_bigquery_dataset.lineage.dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${google_service_account.dbt.email}"
}

resource "google_service_account_iam_member" "dbt_local_impersonation" {
  service_account_id = google_service_account.dbt.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "user:${local.bigquery_rls_admin_email}"
}

resource "google_kms_crypto_key_iam_member" "dbt_bigquery_kms" {
  crypto_key_id = google_kms_crypto_key.bigquery_dataset_key.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_service_account.dbt.email}"
}
