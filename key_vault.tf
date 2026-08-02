# Key Vault Service Account & IAM Bindings
# Provisions infrastructure for chameleon-key-vault microservice
# (deterministic encryption, key lifecycle, cryptographic shredding)

# Service Account for Key Vault Microservice
resource "google_service_account" "key_vault" {
  account_id   = "${var.app_name}-key-vault-${local.instance_short}"
  display_name = "Chameleon Key Vault (${local.instance_name})"
  description  = "Service account for Key Vault microservice - handles deterministic encryption, key generation, and cryptographic shredding"
}

# Allow Key Vault to sign certificates using the asymmetric signing key
resource "google_kms_crypto_key_iam_member" "key_vault_signing_operator" {
  crypto_key_id = google_kms_crypto_key.certificate_signing_key.id
  role          = "roles/cloudkms.signerVerifier"
  member        = "serviceAccount:${google_service_account.key_vault.email}"
}

# IAM: Key Vault SA can publish to lineage stream
resource "google_pubsub_topic_iam_member" "key_vault_lineage_publisher" {
  topic  = google_pubsub_topic.pii_lineage_events.name
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${google_service_account.key_vault.email}"
}

resource "google_pubsub_topic_iam_member" "key_vault_pubsub_publisher" {
  topic  = google_pubsub_topic.janitor_dlq.name
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${google_service_account.key_vault.email}"
}

locals {
  key_vault_service_name = coalesce(var.key_vault_service_name, "${var.app_name}-key-vault-${local.instance_name}")

  # Preserve the already-applied dev service account ID exactly (no rename);
  # every other instance — including prod, and any new customer — uses the
  # short form, since even prod's existing form is already at GCP's 30-char
  # account_id ceiling with nothing to spare for a longer instance_short.
  key_vault_deployer_service_account_id = coalesce(
    var.key_vault_deployer_service_account_id,
    (local.is_legacy_instance && local.instance_name == "dev") ? "${var.app_name}-key-vault-deploy-${local.instance_short}" : "${var.app_name}-kv-deploy-${local.instance_short}"
  )
}

# Artifact Registry Docker repository for Key Vault application images.
resource "google_artifact_registry_repository" "key_vault" {
  location      = var.gcp_region
  repository_id = var.key_vault_artifact_repository_id
  description   = var.key_vault_artifact_repository_description
  format        = "DOCKER"

  cleanup_policy_dry_run = false

  cleanup_policies {
    id     = "keep-recent-images"
    action = "KEEP"

    most_recent_versions {
      keep_count = var.key_vault_artifact_cleanup_keep_count
    }
  }

  cleanup_policies {
    id     = "delete-untagged-after-30-days"
    action = "DELETE"

    condition {
      tag_state  = "UNTAGGED"
      older_than = "2592000s"
    }
  }

  labels = merge(var.labels, {
    environment = var.environment
    component   = "key-vault"
  })

  depends_on = [google_project_service.artifactregistry]
}

# Service Account for GitHub Actions Key Vault deployments.
resource "google_service_account" "key_vault_deployer" {
  account_id   = local.key_vault_deployer_service_account_id
  display_name = "Chameleon Key Vault Deployer (${local.instance_name})"
  description  = "GitHub Actions deploy identity for Key Vault container pushes and Cloud Run deployments"
}

# Least-privilege KMS role for the Key Vault runtime. This permits using the
# dedicated application key and destroying key versions without granting KMS admin.
resource "google_project_iam_custom_role" "key_vault_kms_operator" {
  # role_id disallows hyphens, so instance_short (hex-only) is used even
  # though this field's 64-char budget wouldn't otherwise require it.
  role_id     = "keyVaultKmsOperator_${local.instance_short}"
  title       = "Key Vault KMS Operator (${local.instance_name})"
  description = "Minimum KMS permissions required by the Key Vault runtime"
  permissions = [
    "cloudkms.cryptoKeys.get",
    "cloudkms.cryptoKeys.create",
    "cloudkms.cryptoKeys.list",
    "cloudkms.cryptoKeyVersions.create",
    "cloudkms.cryptoKeyVersions.destroy",
    "cloudkms.cryptoKeyVersions.get",
    "cloudkms.cryptoKeyVersions.list",
    "cloudkms.cryptoKeyVersions.useToDecrypt",
    "cloudkms.cryptoKeyVersions.useToEncrypt",
    "cloudkms.keyRings.get",
    "cloudkms.keyRings.list",
  ]
}

# IAM: Key Vault SA permissions at the Key Ring level to support ensureTenantKey (Dynamic KMS)
resource "google_kms_key_ring_iam_member" "key_vault_ring_operator" {
  key_ring_id = google_kms_key_ring.regional.id
  role        = google_project_iam_custom_role.key_vault_kms_operator.name
  member      = "serviceAccount:${google_service_account.key_vault.email}"
}

# IAM: Key Vault SA can encrypt/decrypt with dynamically-created tenant keys.
resource "google_kms_key_ring_iam_member" "key_vault_ring_encrypter_decrypter" {
  key_ring_id = google_kms_key_ring.regional.id
  role        = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member      = "serviceAccount:${google_service_account.key_vault.email}"
}

# IAM: Key Vault can use Cloud KMS keys (encrypt/decrypt operations)
# BigQuery Dataset Key
resource "google_kms_crypto_key_iam_member" "key_vault_bigquery_kms" {
  crypto_key_id = google_kms_crypto_key.bigquery_dataset_key.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_service_account.key_vault.email}"
}

# Firestore Key
resource "google_kms_crypto_key_iam_member" "key_vault_firestore_kms" {
  count         = var.enable_firestore_cmek ? 1 : 0
  crypto_key_id = google_kms_crypto_key.firestore_key.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_service_account.key_vault.email}"
}

# GCS Key
resource "google_kms_crypto_key_iam_member" "key_vault_gcs_kms" {
  crypto_key_id = google_kms_crypto_key.gcs_key.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_service_account.key_vault.email}"
}

resource "google_kms_crypto_key_iam_member" "key_vault_application_kms" {
  crypto_key_id = google_kms_crypto_key.key_vault_key.id
  role          = google_project_iam_custom_role.key_vault_kms_operator.name
  member        = "serviceAccount:${google_service_account.key_vault.email}"
}

# Dedicated Key Ring for Asymmetric Signing Operations
resource "google_kms_key_ring" "signing" {
  name       = "chameleon-signing-${local.instance_name}"
  location   = var.kms_region
  depends_on = [google_project_service.kms]
}

# Cloud KMS Key - Asymmetric signing for Certificates of Destruction (Phase 4)
resource "google_kms_crypto_key" "certificate_signing_key" {
  name     = "chameleon-cert-signing-${local.instance_name}"
  key_ring = google_kms_key_ring.signing.id
  purpose  = "ASYMMETRIC_SIGN"

  version_template {
    algorithm        = "RSA_SIGN_PSS_2048_SHA256"
    protection_level = "SOFTWARE"
  }

  lifecycle {
    prevent_destroy = true
  }

  labels = merge(var.labels, {
    component = "key-vault"
    purpose   = "certificate-of-destruction-signing"
  })
}

resource "google_kms_crypto_key_iam_member" "key_vault_signing_kms" {
  crypto_key_id = google_kms_crypto_key.certificate_signing_key.id
  role          = "roles/cloudkms.signerVerifier"
  member        = "serviceAccount:${google_service_account.key_vault.email}"
}

# IAM: Key Vault can list key versions to support automatic JWKS generation (Phase 4)
resource "google_kms_crypto_key_iam_member" "key_vault_signing_viewer" {
  crypto_key_id = google_kms_crypto_key.certificate_signing_key.id
  role          = "roles/cloudkms.viewer"
  member        = "serviceAccount:${google_service_account.key_vault.email}"
}

# Least-privilege role for POST /admin/signing-key/rotate: mint a new
# version (that's the entire operation -- see the role's own comment for why
# there's no separate promote-to-primary step). Deliberately narrower than
# roles/cloudkms.admin, which would also let the runtime change this key's
# own IAM bindings -- signerVerifier/viewer above already cover everything
# else rotation needs (signing, listing/reading versions).
resource "google_project_iam_custom_role" "key_vault_signing_kms_operator" {
  role_id     = "keyVaultSigningKmsOperator_${local.instance_short}"
  title       = "Key Vault Signing Key Rotator (${local.instance_name})"
  description = "Minimum KMS permissions to rotate the Certificate of Destruction signing key"
  # No cloudkms.cryptoKeys.update -- GCP KMS has no "primary version" concept
  # for ASYMMETRIC_SIGN keys (UpdateCryptoKeyPrimaryVersion rejects it with
  # FAILED_PRECONDITION), so there's no promote-to-primary step to grant for.
  # Minting a version is the entire rotation operation now.
  permissions = [
    "cloudkms.cryptoKeyVersions.create",
  ]
}

resource "google_kms_crypto_key_iam_member" "key_vault_signing_rotator" {
  crypto_key_id = google_kms_crypto_key.certificate_signing_key.id
  role          = google_project_iam_custom_role.key_vault_signing_kms_operator.name
  member        = "serviceAccount:${google_service_account.key_vault.email}"
}

# IAM: Key Vault can read/write Firestore (public ledger + user key registry)
resource "google_project_iam_member" "key_vault_firestore" {
  project = var.gcp_project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.key_vault.email}"
}

# IAM: Key Vault can read Secret Manager (for CMEK metadata)
resource "google_secret_manager_secret_iam_member" "key_vault_secret" {
  secret_id = google_secret_manager_secret.cmek_master_key.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.key_vault.email}"
}


# Key Vault API Key — authenticates callers (console, pipelines) to Key Vault
resource "google_secret_manager_secret" "vault_api_key" {
  secret_id = "vault-api-key-${local.instance_name}"

  replication {
    auto {}
  }

  labels = merge(var.labels, {
    component = "key-vault"
    purpose   = "vault-auth"
  })
}

# For Chameleon's own dev/prod (auto_generate_secrets = false), the token VALUE
# stays manually managed — set and rotate it directly in Secret Manager
# (gcloud secrets versions add vault-api-key-<instance> --data-file=-).
# Terraform only owns the secret container + IAM. The `removed` block drops the
# old placeholder version from state without destroying any live version.
removed {
  from = google_secret_manager_secret_version.vault_api_key_version

  lifecycle {
    destroy = false
  }
}

# Any new instance (auto_generate_secrets = true) gets a value generated and
# populated automatically, so onboarding needs no manual Secret Manager step.
# A distinct resource address from the removed `vault_api_key_version` above —
# Terraform disallows redeclaring an address a `removed` block targets.
resource "random_password" "vault_api_key" {
  count   = local.auto_generate_secrets ? 1 : 0
  length  = 32
  special = false
}

resource "google_secret_manager_secret_version" "vault_api_key_generated" {
  count       = local.auto_generate_secrets ? 1 : 0
  secret      = google_secret_manager_secret.vault_api_key.id
  secret_data = random_password.vault_api_key[0].result
}

resource "google_secret_manager_secret_iam_member" "key_vault_vault_api_key" {
  secret_id = google_secret_manager_secret.vault_api_key.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.key_vault.email}"
}

# PII Registry write token — shared secret gating the declare API (POST/PUT/DELETE
# /pii-registry/resources). The Console proxy sends the same value. The token VALUE is
# not managed by Terraform — set/rotate it directly in Secret Manager.
resource "google_secret_manager_secret" "pii_registry_write_token" {
  secret_id = "pii-registry-write-token-${local.instance_name}"

  replication {
    auto {}
  }

  labels = merge(var.labels, {
    component = "key-vault"
    purpose   = "pii-registry-write-auth"
  })
}

removed {
  from = google_secret_manager_secret_version.pii_registry_write_token_version

  lifecycle {
    destroy = false
  }
}

resource "random_password" "pii_registry_write_token" {
  count   = local.auto_generate_secrets ? 1 : 0
  length  = 32
  special = false
}

resource "google_secret_manager_secret_version" "pii_registry_write_token_generated" {
  count       = local.auto_generate_secrets ? 1 : 0
  secret      = google_secret_manager_secret.pii_registry_write_token.id
  secret_data = random_password.pii_registry_write_token[0].result
}

resource "google_secret_manager_secret_iam_member" "key_vault_pii_registry_write_token" {
  secret_id = google_secret_manager_secret.pii_registry_write_token.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.key_vault.email}"
}

# Console access-gate password (app-level, read by the console's own proxy.ts
# CONSOLE_PASSWORD check — see chameleon-console). Brand new secret, no
# pre-existing manual-management precedent to preserve, so it is always
# generated regardless of auto_generate_secrets. IAM grant to the console's
# runtime service account is added in Phase 4 once that service account
# exists (the console does not yet have its own Cloud Run deployment).
resource "google_secret_manager_secret" "console_password" {
  secret_id = "console-password-${local.instance_name}"

  replication {
    auto {}
  }

  labels = merge(var.labels, {
    component = "console"
    purpose   = "console-auth"
  })
}

resource "random_password" "console_password" {
  length  = 24
  special = false
}

resource "google_secret_manager_secret_version" "console_password_generated" {
  secret      = google_secret_manager_secret.console_password.id
  secret_data = random_password.console_password.result
}

# SaaS Integration Secrets
resource "google_secret_manager_secret" "hubspot_api_key" {
  secret_id = "hubspot-api-key-${local.instance_name}"

  replication {
    auto {}
  }

  labels = merge(var.labels, {
    component = "saas-integration"
    purpose   = "hubspot-auth"
  })
}

resource "google_secret_manager_secret_version" "hubspot_api_key_version" {
  secret      = google_secret_manager_secret.hubspot_api_key.id
  secret_data = "placeholder-hubspot-api-key" # Replace with actual key or use external mechanism

  # Ignore changes to secret_data to prevent Terraform from trying to update it
  # every time the placeholder is changed, assuming external management.
  lifecycle { ignore_changes = [secret_data] }
}

resource "google_secret_manager_secret" "salesforce_api_key" {
  secret_id = "salesforce-api-key-${local.instance_name}"

  replication {
    auto {}
  }

  labels = merge(var.labels, {
    component = "saas-integration"
    purpose   = "salesforce-auth"
  })
}

resource "google_secret_manager_secret_version" "salesforce_api_key_version" {
  secret      = google_secret_manager_secret.salesforce_api_key.id
  secret_data = "placeholder-salesforce-api-key" # Replace with actual key or use external mechanism

  lifecycle { ignore_changes = [secret_data] }
}

resource "google_secret_manager_secret_iam_member" "key_vault_hubspot_secret" {
  secret_id = google_secret_manager_secret.hubspot_api_key.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.key_vault.email}"
}

resource "google_secret_manager_secret_iam_member" "key_vault_salesforce_secret" {
  secret_id = google_secret_manager_secret.salesforce_api_key.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.key_vault.email}"
}

# IAM: Key Vault can write to GCS (for audit evidence buckets)
resource "google_storage_bucket_iam_member" "key_vault_audit_bucket_writer" {
  bucket = google_storage_bucket.audit_logs.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.key_vault.email}"
}

# IAM: Key Vault can read back its own previously-stored certificates --
# needed by GET /certificate/:userId, which returns the exact certificate
# that was actually issued (see certificate-service.ts's
# getCertificateForUser) instead of re-signing a fresh one on every call.
# objectCreator above is write-only and doesn't cover this.
resource "google_storage_bucket_iam_member" "key_vault_audit_bucket_reader" {
  bucket = google_storage_bucket.audit_logs.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.key_vault.email}"
}

# IAM: Key Vault can read from landing zone bucket (for lineage tracking)
resource "google_storage_bucket_iam_member" "key_vault_landing_bucket_reader" {
  bucket = google_storage_bucket.landing_zone.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.key_vault.email}"
}

# IAM: Key Vault can read BigQuery dataset (for lineage queries and public ledger table)
resource "google_bigquery_dataset_iam_member" "key_vault_bigquery_viewer" {
  dataset_id = google_bigquery_dataset.chameleon.dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${google_service_account.key_vault.email}"
}

# IAM: Key Vault can insert/update BigQuery rows (for public ledger table + deletion tracking)
resource "google_bigquery_dataset_iam_member" "key_vault_bigquery_editor" {
  dataset_id = google_bigquery_dataset.chameleon.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.key_vault.email}"
}

# IAM: Key Vault can edit Lineage dataset
resource "google_bigquery_dataset_iam_member" "key_vault_lineage_editor" {
  dataset_id = google_bigquery_dataset.lineage.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.key_vault.email}"
}

# IAM: Key Vault can insert into the compliance dataset (audit mirror of PII
# declarations into compliance.pii_metadata_registry).
# Gated off by default: adding this binding requires the Terraform identity to own the
# compliance dataset (bigquery.datasets.update). Enable once that ownership is granted.
resource "google_bigquery_dataset_iam_member" "key_vault_compliance_editor" {
  count      = var.enable_pii_audit_mirror ? 1 : 0
  dataset_id = google_bigquery_dataset.compliance.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.key_vault.email}"
}

# IAM: Key Vault can run BigQuery jobs (for deletion queries and lineage analysis)
resource "google_project_iam_member" "key_vault_bigquery_job_user" {
  project = var.gcp_project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.key_vault.email}"
}

# IAM: Key Vault can read table/column schema (INFORMATION_SCHEMA) across the
# whole project, for the Declare form's live column picker. Project-scoped
# because a declared resource can live in any dataset, not just Chameleon's
# own. metadataViewer, deliberately not dataViewer -- this only needs to see
# column names/types, never read actual row data.
resource "google_project_iam_member" "key_vault_bigquery_metadata_viewer" {
  project = var.gcp_project_id
  role    = "roles/bigquery.metadataViewer"
  member  = "serviceAccount:${google_service_account.key_vault.email}"
}

# IAM: Key Vault writes application logs to Cloud Logging.
resource "google_project_iam_member" "key_vault_logging" {
  project = var.gcp_project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.key_vault.email}"
}

# IAM: GitHub Actions deploy identity can push Key Vault images.
resource "google_artifact_registry_repository_iam_member" "key_vault_deployer_artifact_writer" {
  location   = google_artifact_registry_repository.key_vault.location
  repository = google_artifact_registry_repository.key_vault.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.key_vault_deployer.email}"
}

resource "google_artifact_registry_repository_iam_member" "key_vault_cloud_run_artifact_reader" {
  location   = google_artifact_registry_repository.key_vault.location
  repository = google_artifact_registry_repository.key_vault.name
  role       = "roles/artifactregistry.reader"
  member     = google_project_service_identity.run.member
}

# BYOC onboarding: grant a customer project's own runtime service account(s)
# read access to Chameleon's pre-built images, so their `terraform apply`
# can pull a pinned image tag without needing their own CI.
resource "google_artifact_registry_repository_iam_member" "key_vault_external_readers" {
  for_each   = toset(var.key_vault_artifact_registry_external_readers)
  location   = google_artifact_registry_repository.key_vault.location
  repository = google_artifact_registry_repository.key_vault.name
  role       = "roles/artifactregistry.reader"
  member     = each.value
}

# IAM: GitHub Actions deploy identity can update Cloud Run and use the runtime SA.
resource "google_project_iam_member" "key_vault_deployer_run_developer" {
  project = var.gcp_project_id
  role    = "roles/run.developer"
  member  = "serviceAccount:${google_service_account.key_vault_deployer.email}"
}

resource "google_service_account_iam_member" "key_vault_deployer_runtime_user" {
  service_account_id = google_service_account.key_vault.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.key_vault_deployer.email}"
}

resource "google_service_account_iam_member" "key_vault_deployer_wif" {
  count = var.enable_workload_identity_federation ? 1 : 0

  service_account_id = google_service_account.key_vault_deployer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github_actions[0].name}/attribute.repository/${var.github_repository_owner}/${var.key_vault_github_repository_name}"
}

# Cloud Run service for the Key Vault API.
resource "google_cloud_run_v2_service" "key_vault" {
  name                = local.key_vault_service_name
  location            = var.gcp_region
  ingress             = var.key_vault_cloud_run_ingress
  deletion_protection = var.environment == "prod"

  lifecycle {
    # Image is managed by the Deploy workflow (GitHub Actions), not Terraform.
    # Terraform controls config; the deploy workflow owns which image is live.
    # scaling fields (min_instance_count=0) are written by gcloud run deploy as explicit zeros;
    # Terraform treats omitted vs 0 as equivalent, so ignore to avoid perpetual drift.
    ignore_changes = [
      template[0].containers[0].image,
      scaling,
    ]
  }

  template {
    service_account = google_service_account.key_vault.email

    labels = merge(var.labels, {
      environment = var.environment
      component   = "key-vault"
    })

    scaling {
      min_instance_count = var.environment == "prod" ? 1 : 0
      max_instance_count = var.environment == "prod" ? 10 : 3
    }

    containers {
      image = var.key_vault_container_image

      ports {
        name           = "http1"
        container_port = 8080
      }

      env {
        name  = "NODE_ENV"
        value = var.environment == "prod" ? "production" : "development"
      }

      # Chameleon's own dev/prod deployments use the bundled connector-slice
      # seed (src/data/pii-registry.ts); fresh BYOC/managed-dedicated
      # deployments leave this unset and start with an empty registry.
      env {
        name  = "PII_REGISTRY_USE_BUNDLED_SEED"
        value = var.key_vault_use_bundled_seed ? "true" : "false"
      }

      env {
        name  = "GCP_PROJECT_ID"
        value = var.gcp_project_id
      }

      env {
        name  = "FIRESTORE_DATABASE_ID"
        value = google_firestore_database.kms_registry.name
      }

      env {
        name  = "FIRESTORE_COLLECTION"
        value = var.key_vault_firestore_collection
      }

      env {
        name  = "CLOUD_KMS_PROJECT_ID"
        value = var.gcp_project_id
      }

      env {
        name  = "CLOUD_KMS_REGION"
        value = var.kms_region
      }

      env {
        name  = "CLOUD_KMS_KEY_RING"
        value = google_kms_key_ring.regional.name
      }

      env {
        name  = "CLOUD_KMS_KEY_NAME"
        value = google_kms_crypto_key.key_vault_key.name
      }

      env {
        name  = "JWKS_ENABLED"
        value = "true"
      }

      env {
        name  = "CLOUD_KMS_SIGNING_KEY_RING"
        value = google_kms_key_ring.signing.name
      }

      env {
        name  = "CLOUD_KMS_SIGNING_KEY_NAME"
        value = google_kms_crypto_key.certificate_signing_key.name
      }

      env {
        name  = "FIRESTORE_DELETION_REQUEST_COLLECTION"
        value = var.key_vault_firestore_deletion_request_collection
      }

      env {
        name  = "GCP_AUDIT_BUCKET_NAME"
        value = google_storage_bucket.audit_logs.name
      }

      env {
        name  = "SECRET_MANAGER_PROJECT_ID"
        value = var.gcp_project_id
      }

      env {
        name  = "CMEK_METADATA_SECRET_NAME"
        value = google_secret_manager_secret.cmek_master_key.secret_id
      }

      env {
        name  = "LOG_PROJECT_ID"
        value = var.gcp_project_id
      }

      env {
        name  = "LOG_LEVEL"
        value = var.key_vault_log_level
      }

      env {
        name  = "DATA_PLANE_URL"
        value = var.data_plane_url
      }

      env {
        name  = "LINEAGE_TOPIC_ID"
        value = google_pubsub_topic.pii_lineage_events.name
      }

      # Lets the console's "Sync Now" button trigger the same on-demand
      # /pii-registry/sync-now route the daily scheduler fires. Deliberately
      # NOT google_cloud_run_v2_service.pii_ingestor_worker[0].uri -- the
      # worker already depends on THIS service's own .uri for VAULT_BASE_URL
      # above, so a reverse reference here is a real Terraform dependency
      # cycle (confirmed via `terraform validate`), not just a style choice.
      # Key Vault resolves the worker's actual URL itself at runtime via the
      # Cloud Run Admin API (see key_vault_worker_viewer below for the read
      # IAM this needs, alongside key_vault_worker_invoker for the call
      # itself), using only these plain, dependency-free values.
      dynamic "env" {
        for_each = var.enable_pii_ingestor_worker ? [1] : []
        content {
          name  = "PII_INGESTOR_WORKER_SERVICE_NAME"
          value = "${var.app_name}-pii-ingestor-worker-${local.instance_name}"
        }
      }

      dynamic "env" {
        for_each = var.enable_pii_ingestor_worker ? [1] : []
        content {
          name  = "PII_INGESTOR_WORKER_REGION"
          value = var.gcp_region
        }
      }

      # Decrypted views (decrypted_views.tf) -- all three env vars omitted
      # entirely, as a group, when the flag is off. main.ts treats an unset
      # DECRYPTED_VIEWS_DATASET as "feature disabled," registering neither
      # route.
      dynamic "env" {
        for_each = var.enable_decrypted_views ? [1] : []
        content {
          name  = "DECRYPTED_VIEWS_DATASET"
          value = google_bigquery_dataset.decrypted_views[0].dataset_id
        }
      }

      dynamic "env" {
        for_each = var.enable_decrypted_views ? [1] : []
        content {
          name  = "DECRYPTED_VIEWS_BATCH_DECRYPT_FUNCTION_REF"
          value = "${var.gcp_project_id}.${google_bigquery_dataset.decrypted_views[0].dataset_id}.${local.decrypted_views_batch_decrypt_routine_id}"
        }
      }

      dynamic "env" {
        for_each = var.enable_decrypted_views ? [1] : []
        content {
          name  = "DECRYPTED_VIEWS_CONNECTION_SA_EMAIL"
          value = google_bigquery_connection.decrypted_views[0].cloud_resource[0].service_account_id
        }
      }

      # The central pii_vault table -- the one and only source every
      # decrypted view is built on top of, never a customer-supplied
      # resource id. Referenced as a literal table name, not
      # google_bigquery_table.pii_vault[0].table_id, since that resource is
      # itself gated by enable_pii_ingestor_worker -- the precondition below
      # on google_bigquery_connection.decrypted_views requires that flag be
      # on, so the table is guaranteed to exist whenever this env var is set.
      dynamic "env" {
        for_each = var.enable_decrypted_views ? [1] : []
        content {
          name  = "PII_VAULT_RESOURCE_ID"
          value = "bigquery:${var.gcp_project_id}.${google_bigquery_dataset.chameleon.dataset_id}.pii_vault"
        }
      }

      # Omitted entirely when key_vault_auth_bypass_enabled is true — Key
      # Vault's own code (main.ts) runs with NO auth check when this env var
      # is absent. Guarded to dev tier only by the variable's own validation.
      dynamic "env" {
        for_each = var.key_vault_auth_bypass_enabled ? [] : [1]
        content {
          name = "VAULT_API_KEY"
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.vault_api_key.secret_id
              version = "latest"
            }
          }
        }
      }

      env {
        name = "HUBSPOT_API_KEY"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.hubspot_api_key.secret_id
            version = "latest"
          }
        }
      }

      env {
        name = "SALESFORCE_API_KEY"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.salesforce_api_key.secret_id
            version = "latest"
          }
        }
      }

      env {
        name  = "JANITOR_DLQ_TOPIC_ID"
        value = google_pubsub_topic.janitor_dlq.id
      }

      # Enables the audit mirror of user-declared PII resources into
      # compliance.pii_metadata_registry. Unset would disable the mirror (Firestore
      # remains the source of truth either way).
      env {
        name  = "PII_AUDIT_DATASET_ID"
        value = var.enable_pii_audit_mirror ? google_bigquery_dataset.compliance.dataset_id : ""
      }

      # Optional Snowflake reader for the dbt-fed PII registry slice. Vars
      # and the secret container live in snowflake.tf; this env wiring has
      # to stay here since it's part of this resource block. All seven env
      # vars are omitted entirely, as a group, when the account var is unset
      # -- no half-configured state, and a plan with it unset shows zero
      # diff to the Cloud Run service (verified against dev 2026-07-18).
      dynamic "env" {
        for_each = var.pii_registry_snowflake_account != null ? [1] : []
        content {
          name  = "PII_REGISTRY_SNOWFLAKE_ACCOUNT"
          value = var.pii_registry_snowflake_account
        }
      }

      dynamic "env" {
        for_each = var.pii_registry_snowflake_account != null ? [1] : []
        content {
          name  = "PII_REGISTRY_SNOWFLAKE_USER"
          value = var.pii_registry_snowflake_user
        }
      }

      dynamic "env" {
        for_each = var.pii_registry_snowflake_account != null ? [1] : []
        content {
          name  = "PII_REGISTRY_SNOWFLAKE_ROLE"
          value = var.pii_registry_snowflake_role
        }
      }

      dynamic "env" {
        for_each = var.pii_registry_snowflake_account != null ? [1] : []
        content {
          name  = "PII_REGISTRY_SNOWFLAKE_WAREHOUSE"
          value = var.pii_registry_snowflake_warehouse
        }
      }

      dynamic "env" {
        for_each = var.pii_registry_snowflake_account != null ? [1] : []
        content {
          name  = "PII_REGISTRY_SNOWFLAKE_DATABASE"
          value = var.pii_registry_snowflake_database
        }
      }

      dynamic "env" {
        for_each = var.pii_registry_snowflake_account != null ? [1] : []
        content {
          name  = "PII_REGISTRY_SNOWFLAKE_SCHEMA"
          value = var.pii_registry_snowflake_schema
        }
      }

      dynamic "env" {
        for_each = var.pii_registry_snowflake_account != null ? [1] : []
        content {
          name = "PII_REGISTRY_SNOWFLAKE_PASSWORD"
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.pii_registry_snowflake_password.secret_id
              version = "latest"
            }
          }
        }
      }

      # Shared secret gating the PII declare API (POST/PUT/DELETE). Unset disables writes.
      env {
        name = "PII_REGISTRY_WRITE_TOKEN"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.pii_registry_write_token.secret_id
            version = "latest"
          }
        }
      }

      env {
        name  = "EXTERNAL_EGRESS_ENABLED"
        value = "true"
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
      }

      startup_probe {
        initial_delay_seconds = 0
        timeout_seconds       = 5
        period_seconds        = 10
        failure_threshold     = 6

        http_get {
          path = "/health"
          port = 8080
        }
      }

      liveness_probe {
        initial_delay_seconds = 10
        timeout_seconds       = 5
        period_seconds        = 30
        failure_threshold     = 3

        http_get {
          path = "/health"
          port = 8080
        }
      }
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  depends_on = [
    google_project_service.run,
    google_project_service.logging,
    google_project_iam_member.key_vault_firestore,
    google_secret_manager_secret_iam_member.key_vault_secret,
    google_kms_crypto_key_iam_member.key_vault_application_kms,
    google_kms_key_ring_iam_member.key_vault_ring_operator,
    google_kms_key_ring_iam_member.key_vault_ring_encrypter_decrypter,
    google_kms_crypto_key_iam_member.key_vault_signing_kms,
    google_kms_crypto_key_iam_member.key_vault_signing_viewer,
    google_project_iam_member.key_vault_logging,
    google_storage_bucket_iam_member.key_vault_audit_bucket_writer,
    google_storage_bucket_iam_member.key_vault_landing_bucket_reader,
    google_secret_manager_secret_iam_member.key_vault_vault_api_key,
    google_secret_manager_secret_iam_member.key_vault_hubspot_secret,
    google_secret_manager_secret_iam_member.key_vault_salesforce_secret,
    google_pubsub_topic_iam_member.key_vault_pubsub_publisher,
    google_secret_manager_secret_iam_member.key_vault_pii_registry_write_token,
    google_secret_manager_secret_version.hubspot_api_key_version,
    google_secret_manager_secret_version.salesforce_api_key_version,
    google_secret_manager_secret_iam_member.key_vault_snowflake_secret,
    google_secret_manager_secret_version.pii_registry_snowflake_password_version
  ]
}

resource "google_cloud_run_v2_service_iam_member" "key_vault_public_invoker" {
  count = var.key_vault_allow_unauthenticated ? 1 : 0

  project  = var.gcp_project_id
  location = google_cloud_run_v2_service.key_vault.location
  name     = google_cloud_run_v2_service.key_vault.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# IAM: Data Plane can read the signing public key from KMS to verify janitor request signatures
resource "google_kms_crypto_key_iam_member" "data_plane_signing_viewer" {
  crypto_key_id = google_kms_crypto_key.certificate_signing_key.id
  role          = "roles/cloudkms.publicKeyViewer"
  member        = "serviceAccount:${google_service_account.pii_ingestor_worker.email}"
}

resource "google_cloud_run_v2_service_iam_member" "key_vault_data_plane_invoker" {
  count    = var.enable_pii_ingestor_worker ? 1 : 0
  project  = var.gcp_project_id
  location = var.gcp_region
  name     = google_cloud_run_v2_service.pii_ingestor_worker[0].name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.key_vault.email}"
}

# Explicit invoker grant for the rotation scheduler below, kept separate from
# key_vault_public_invoker -- that one is conditional on
# key_vault_allow_unauthenticated (false by default for BYOC/customer
# deployments), so machine-to-machine callers need their own grant to work
# regardless of that setting. Key Vault invokes itself here: no new service
# account needed, it already has an identity and this doesn't broaden what
# that identity can already reach.
resource "google_cloud_run_v2_service_iam_member" "key_vault_self_invoker" {
  project  = var.gcp_project_id
  location = google_cloud_run_v2_service.key_vault.location
  name     = google_cloud_run_v2_service.key_vault.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.key_vault.email}"
}

# Reads the CURRENT value of the shared API key so the scheduler job below
# can authenticate past Key Vault's own app-level auth hook (main.ts) --
# that hook is the real perimeter here (Cloud Run's own IAM is bypassed
# entirely when key_vault_allow_unauthenticated=true, Chameleon's own
# dev/prod setting). Requires whatever identity runs `terraform apply` to
# have secretmanager.versions.access on this secret.
data "google_secret_manager_secret_version" "vault_api_key_current" {
  secret  = google_secret_manager_secret.vault_api_key.secret_id
  version = "latest"
}

# Periodically rotates the Certificate of Destruction signing key: mints a
# new KMS key version, which the app treats as "current" simply for being
# the newest ENABLED one (see certificate-service.ts's
# getCurrentSigningKeyVersion). Old versions are never destroyed (see
# getJwks()), so this only ever adds a key to the JWKS response -- it can't
# invalidate a previously-issued certificate. Same OIDC + Cloud Scheduler
# pattern as pii_vault_sync above.
resource "google_cloud_scheduler_job" "signing_key_rotation" {
  name        = "${var.app_name}-signing-key-rotation-${local.instance_name}"
  description = "Periodically rotates the Certificate of Destruction signing key"
  schedule    = var.signing_key_rotation_schedule
  region      = var.gcp_region
  time_zone   = "Etc/UTC"

  http_target {
    http_method = "POST"
    uri         = "${google_cloud_run_v2_service.key_vault.uri}/admin/signing-key/rotate"

    headers = {
      "x-api-key" = data.google_secret_manager_secret_version.vault_api_key_current.secret_data
    }

    oidc_token {
      service_account_email = google_service_account.key_vault.email
      audience              = google_cloud_run_v2_service.key_vault.uri
    }
  }

  depends_on = [
    google_project_service.cloudscheduler,
    google_cloud_run_v2_service_iam_member.key_vault_self_invoker,
    google_kms_crypto_key_iam_member.key_vault_signing_rotator,
  ]
}
