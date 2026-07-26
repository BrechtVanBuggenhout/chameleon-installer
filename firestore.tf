# Firestore Database - KMS Key Registry Backend
# NOTE: This is a cost-optimized approach for MVP/project use.
# For production, migrate to Cloud SQL (PostgreSQL) for ACID guarantees and audit trails.
resource "google_firestore_database" "kms_registry" {
  project     = var.gcp_project_id
  name        = var.firestore_database_id
  location_id = var.firestore_region
  type        = "FIRESTORE_NATIVE"

  # Deliberately, explicitly disabled -- this database holds the wrapped
  # per-user DEKs. Crypto-shredding a user means deleting their key record
  # here; if PITR were ever enabled, that "destroyed" key would still be
  # recoverable from a snapshot for the whole retention window, silently
  # defeating the deletion guarantee. Left unset, this defaults to disabled
  # anyway -- pinning it explicitly turns that into a documented guarantee
  # instead of an accident someone could enable later without realizing
  # what it undoes.
  point_in_time_recovery_enablement = "POINT_IN_TIME_RECOVERY_DISABLED"

  dynamic "cmek_config" {
    for_each = var.enable_firestore_cmek ? [google_kms_crypto_key.firestore_key.id] : []

    content {
      kms_key_name = cmek_config.value
    }
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [
    google_project_service.firestore
  ]
}

# Firestore Composite Index for tenant-scoped Deletion Request State Machine
resource "google_firestore_index" "deletion_requests_query" {
  project    = var.gcp_project_id
  database   = google_firestore_database.kms_registry.name
  collection = "deletion_requests"

  fields {
    field_path = "user_id"
    order      = "ASCENDING"
  }

  fields {
    field_path = "tenant_id"
    order      = "ASCENDING"
  }

  fields {
    field_path = "status"
    order      = "ASCENDING"
  }

  fields {
    field_path = "created_at"
    order      = "DESCENDING"
  }
}

# Firestore Composite Index for User DEK Lookups
resource "google_firestore_index" "user_keys_query" {
  project    = var.gcp_project_id
  database   = google_firestore_database.kms_registry.name
  collection = "keys"

  fields {
    field_path = "userId"
    order      = "ASCENDING"
  }

  fields {
    field_path = "version"
    order      = "DESCENDING"
  }

  fields {
    field_path = "createdAt"
    order      = "DESCENDING"
  }
}

# Firestore Composite Index for Tenant Key Lookups (SaaS Lifecycle)
resource "google_firestore_index" "tenant_keys_query" {
  project    = var.gcp_project_id
  database   = google_firestore_database.kms_registry.name
  collection = "keys"

  fields {
    field_path = "tenantId"
    order      = "ASCENDING"
  }

  fields {
    field_path = "status"
    order      = "ASCENDING"
  }

  fields {
    field_path = "createdAt"
    order      = "DESCENDING"
  }
}

# IAM: GCP-managed Firestore service agent needs KMS access for CMEK
resource "google_kms_crypto_key_iam_member" "firestore_service_agent_kms" {
  count = var.enable_firestore_cmek ? 1 : 0

  crypto_key_id = google_kms_crypto_key.firestore_key.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-firestore.iam.gserviceaccount.com"
}
