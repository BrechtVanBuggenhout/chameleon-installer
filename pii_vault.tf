# Central PII vault: retroactive protection for tables the customer already
# owns (Fivetran-created, hand-built, whatever) that were never going to flow
# through Chameleon's own ingestion pipeline. Same shape and same CMEK key as
# raw_users.pii_fields (see bigquery.tf) -- this is that pattern applied to
# arbitrary declared resources instead of just the canonical ingestion table,
# tagged with which source resource each row came from so multiple declared
# tables can land in one place. Populated by a daily sync job (pii-vault-sync
# scheduler below), never written to directly, and never touches the source
# table itself -- redacting the source's own plaintext is a separate, later,
# opt-in decision, not part of this.
resource "google_bigquery_table" "pii_vault" {
  count       = var.enable_pii_ingestor_worker ? 1 : 0
  dataset_id  = google_bigquery_dataset.chameleon.dataset_id
  table_id    = "pii_vault"
  description = "Central encrypted PII store for manually-declared resources, synced daily from their source tables. One row per (tenant_id, user_id, resource_id, field_name) -- that's the natural unique key, not the whole row -- so adding a newly-declared field to an already-synced resource just appends the missing rows for existing users rather than requiring any update-in-place. Join on (tenant_id, user_id) for real values via Key Vault's /decrypt; crypto-shredding a user's key makes every row for that user permanently unreadable, regardless of how many rows they have here."

  # Matches raw_users' precedent below (see its own comment): BigQuery can't
  # ALTER a REPEATED RECORD column into flat scalar columns in place, so a
  # schema change like the nested->flat one this table just went through
  # requires Terraform to destroy and recreate it -- which the provider's
  # deletion_protection default (true when unset) blocks outright. Hit for
  # real: both dev and prod CI failed on this exact table with "cannot
  # destroy table ... without setting deletion_protection=false" right after
  # merging that schema change.
  deletion_protection = false

  clustering = ["tenant_id", "user_id", "resource_id", "field_name"]

  encryption_configuration {
    kms_key_name = google_kms_crypto_key.bigquery_dataset_key.id
  }

  schema = jsonencode([
    {
      name        = "tenant_id"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "The unique identifier for the SaaS tenant"
    },
    {
      name        = "user_id"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Unique user identifier, per the declared resource's userIdColumn"
    },
    {
      name        = "resource_id"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Which declared PII registry resource this row was synced from, e.g. bigquery:project.dataset.federated_user"
    },
    {
      name        = "field_name"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Declared PII field name this row encrypts, e.g. 'email' or 'phone' -- one row per field, not a nested array, so this is part of this row's identity"
    },
    {
      name        = "key_id"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "UUID of the specific key version used to encrypt this row's value"
    },
    {
      name        = "token"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "HMAC-SHA256 token of this field's value for deterministic joins"
    },
    {
      name        = "encrypted_value"
      type        = "BYTES"
      mode        = "NULLABLE"
      description = "Encrypted value for this field (CMEK encrypted)"
    },
    {
      name        = "synced_at"
      type        = "TIMESTAMP"
      mode        = "NULLABLE"
      description = "When this row was written by the daily sync job"
    }
  ])

  labels = {
    layer = "vault"
  }
}

# IAM: no new grants needed -- data_pipeline already holds project-level
# bigquery.dataEditor + bigquery.jobUser (service_account_data_pipeline.tf)
# and cloudkms.cryptoKeyEncrypterDecrypter on this same bigquery_dataset_key
# (also already granted), which together cover reading any same-project
# source table and writing this table. Cross-project source tables are a
# separate, not-yet-built scoping exercise.

# Daily backfill/sync into the PII vault for every manually-declared
# resource: finds user IDs not yet present in pii_vault for that resource,
# encrypts their declared fields, and inserts them. Exact same pattern as
# warehouse_metadata_crawl below -- same SA, same auth, just a different
# endpoint -- so new/added rows in an already-declared table get picked up
# automatically without a one-time backfill ever going stale.
resource "google_cloud_scheduler_job" "pii_vault_sync" {
  count       = var.enable_pii_ingestor_worker ? 1 : 0
  name        = "${var.app_name}-pii-vault-sync-${local.instance_name}"
  description = "Daily backfill/sync of manually-declared resources into the central PII vault"
  schedule    = var.pii_vault_sync_schedule
  region      = var.gcp_region
  time_zone   = "Etc/UTC"

  http_target {
    http_method = "POST"
    uri         = "${google_cloud_run_v2_service.pii_ingestor_worker[0].uri}/api/v1/pii-vault-sync"

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
