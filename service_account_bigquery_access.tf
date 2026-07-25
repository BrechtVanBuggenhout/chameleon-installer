# Service Account for BigQuery Access
resource "google_service_account" "bigquery_access" {
  account_id   = "${var.app_name}-bq-access-${local.instance_short}"
  display_name = "Chameleon BigQuery Access (${local.instance_name})"
  description  = "Service account for BigQuery operations"
}

resource "google_project_iam_member" "bigquery_access_editor" {
  project = var.gcp_project_id
  role    = "roles/bigquery.dataEditor"
  member  = "serviceAccount:${google_service_account.bigquery_access.email}"
}

resource "google_project_iam_member" "bigquery_access_job" {
  project = var.gcp_project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.bigquery_access.email}"
}

resource "google_kms_crypto_key_iam_member" "bigquery_access_kms" {
  crypto_key_id = google_kms_crypto_key.bigquery_dataset_key.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_service_account.bigquery_access.email}"
}
