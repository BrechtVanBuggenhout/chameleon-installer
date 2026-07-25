# Regional Cloud KMS Key Ring - Firestore and GCS CMEK
resource "google_kms_key_ring" "regional" {
  name     = "chameleon-${local.instance_name}"
  location = var.kms_region

  depends_on = [google_project_service.kms]
}

# BigQuery Cloud KMS Key Ring
# BigQuery multi-region datasets require matching KMS multi-region locations.
resource "google_kms_key_ring" "bigquery" {
  name     = "chameleon-bq-${local.instance_name}"
  location = local.bigquery_kms_location

  depends_on = [google_project_service.kms]
}

# Legacy Cloud KMS Key - Previous BigQuery Encryption Key
# Kept at its original Terraform address so Phase 2 does not destroy protected KMS material.
resource "google_kms_crypto_key" "bigquery_key" {
  name            = "chameleon-bq-${local.instance_name}"
  key_ring        = google_kms_key_ring.regional.id
  rotation_period = var.kms_rotation_period
  lifecycle {
    prevent_destroy = true
  }

  labels = merge(var.labels, {
    component = "encryption"
    purpose   = "legacy-bigquery-cmek"
  })
}

# Cloud KMS Key - BigQuery Dataset Encryption
resource "google_kms_crypto_key" "bigquery_dataset_key" {
  name            = "chameleon-bq-${local.instance_name}"
  key_ring        = google_kms_key_ring.bigquery.id
  rotation_period = var.kms_rotation_period
  lifecycle {
    prevent_destroy = true
  }

  labels = merge(var.labels, {
    component = "encryption"
    purpose   = "bigquery-cmek"
  })
}

# Cloud KMS Key - Firestore Database Encryption
resource "google_kms_crypto_key" "firestore_key" {
  name            = "chameleon-firestore-${local.instance_name}"
  key_ring        = google_kms_key_ring.regional.id
  rotation_period = var.kms_rotation_period
  lifecycle {
    prevent_destroy = true
  }

  labels = merge(var.labels, {
    component = "encryption"
    purpose   = "firestore-cmek"
  })
}

# Cloud KMS Key - GCS Landing Zone Encryption
resource "google_kms_crypto_key" "gcs_key" {
  name            = "chameleon-gcs-${local.instance_name}"
  key_ring        = google_kms_key_ring.regional.id
  rotation_period = var.kms_rotation_period
  lifecycle {
    prevent_destroy = true
  }

  labels = merge(var.labels, {
    component = "encryption"
    purpose   = "gcs-cmek"
  })
}

# Cloud KMS Key - Key Vault application encryption/destruction workflows
resource "google_kms_crypto_key" "key_vault_key" {
  name            = "chameleon-key-vault-${local.instance_name}"
  key_ring        = google_kms_key_ring.regional.id
  rotation_period = var.kms_rotation_period

  lifecycle {
    prevent_destroy = true
  }

  labels = merge(var.labels, {
    component = "key-vault"
    purpose   = "application-key-management"
  })
}

# Cloud Secret Manager Secret - CMEK Master Key Metadata
# Stores reference to master encryption key for key rotation and access control
resource "google_secret_manager_secret" "cmek_master_key" {
  secret_id = "chameleon-cmek-master-${local.instance_name}"

  replication {
    auto {}
  }

  labels = merge(var.labels, {
    component = "encryption"
    purpose   = "cmek-metadata"
  })

  depends_on = [google_project_service.secretmanager]
}

# Cloud Secret Manager Secret Version - CMEK Key Metadata
# Contains metadata about the master key (not the key material itself, which lives in KMS)
resource "google_secret_manager_secret_version" "cmek_master_key_version" {
  secret = google_secret_manager_secret.cmek_master_key.id
  secret_data = jsonencode({
    regional_key_ring_name = google_kms_key_ring.regional.name
    bigquery_key_ring_name = google_kms_key_ring.bigquery.name
    bigquery_key_name      = google_kms_crypto_key.bigquery_dataset_key.name
    legacy_bigquery_key    = google_kms_crypto_key.bigquery_key.name
    firestore_key_name     = google_kms_crypto_key.firestore_key.name
    gcs_key_name           = google_kms_crypto_key.gcs_key.name
    key_vault_key_name     = google_kms_crypto_key.key_vault_key.name
    rotation_period        = var.kms_rotation_period
    environment            = var.environment
  })

  lifecycle {
    ignore_changes = [secret_data]
  }
}
