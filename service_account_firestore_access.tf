# Service Account for Firestore Access
resource "google_service_account" "firestore_access" {
  account_id   = "${var.app_name}-fs-access-${local.instance_short}"
  display_name = "Chameleon Firestore Access (${local.instance_name})"
  description  = "Service account for Firestore KMS registry operations"
}

resource "google_project_iam_member" "firestore_access_user" {
  project = var.gcp_project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.firestore_access.email}"
}

resource "google_kms_crypto_key_iam_member" "firestore_access_kms" {
  crypto_key_id = google_kms_crypto_key.firestore_key.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_service_account.firestore_access.email}"
}

resource "google_secret_manager_secret_iam_member" "firestore_access_secret" {
  secret_id = google_secret_manager_secret.cmek_master_key.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.firestore_access.email}"
}
