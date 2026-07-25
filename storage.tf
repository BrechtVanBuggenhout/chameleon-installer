# Cloud Storage Bucket - Landing Zone
resource "google_storage_bucket" "landing_zone" {
  name          = var.gcs_bucket_name
  location      = var.gcp_region
  force_destroy = var.environment == "dev" ? true : false

  uniform_bucket_level_access = true
  storage_class               = var.gcs_storage_class

  versioning {
    enabled = var.environment == "prod" ? true : false
  }

  encryption {
    default_kms_key_name = google_kms_crypto_key.gcs_key.id
  }

  # Defense-in-depth backstop, not the primary control: the ingestion
  # pipeline now deletes source files itself immediately on success (see
  # chameleon-data-pipelines' gcs_monitor.py). These rules bound the two
  # cases the app code doesn't fully own -- a file that never gets picked up
  # at all, and a failed/ copy kept around for debugging -- so a plaintext
  # PII file can't sit here indefinitely either way. Also expires noncurrent
  # versions, since prod has bucket versioning on and an old version would
  # otherwise retain a plaintext copy past its current-version lifetime.
  lifecycle_rule {
    condition {
      matches_prefix = ["inbound/"]
      age            = 7
    }
    action {
      type = "Delete"
    }
  }

  lifecycle_rule {
    condition {
      matches_prefix = ["failed/"]
      age            = 30
    }
    action {
      type = "Delete"
    }
  }

  lifecycle_rule {
    condition {
      with_state = "ARCHIVED"
      age        = 1
    }
    action {
      type = "Delete"
    }
  }

  labels = merge(var.labels, {
    environment = var.environment
    component   = "landing-zone"
  })

  depends_on = [
    google_project_service.storage,
    google_kms_crypto_key_iam_member.gcs_service_agent_kms
  ]
}

# Cloud Storage Bucket - Durable Audit Evidence Destination
resource "google_storage_bucket" "audit_logs" {
  name                        = local.audit_log_bucket_name
  location                    = var.gcp_region
  force_destroy               = false
  uniform_bucket_level_access = true
  storage_class               = var.environment == "prod" ? "ARCHIVE" : "STANDARD"

  versioning {
    enabled = true
  }

  retention_policy {
    retention_period = var.audit_log_retention_days * 86400
    is_locked        = var.audit_log_retention_lock
  }

  encryption {
    default_kms_key_name = google_kms_crypto_key.gcs_key.id
  }

  labels = merge(var.labels, {
    environment = var.environment
    component   = "audit-evidence"
  })

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [
    google_project_service.storage,
    google_kms_crypto_key_iam_member.gcs_service_agent_kms
  ]
}

# Placeholder for the Certificate of Destruction folder structure.
# Note: Sub-folders (YYYY/MM/DD) are created dynamically by the writer service.
resource "google_storage_bucket_object" "certificates_root" {
  name    = "certificates/"
  content = " " # Creates a 0-byte object to make the prefix visible in the UI
  bucket  = google_storage_bucket.audit_logs.name
}

# IAM: GCP-managed GCS service agent needs KMS access for CMEK
resource "google_kms_crypto_key_iam_member" "gcs_service_agent_kms" {
  crypto_key_id = google_kms_crypto_key.gcs_key.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = data.google_storage_project_service_account.gcs.member
}
