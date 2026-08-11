output "firestore_database_name" {
  description = "Firestore database name"
  value       = google_firestore_database.kms_registry.name
}

output "firestore_region" {
  description = "Firestore region"
  value       = var.firestore_region
}

output "bigquery_dataset_id" {
  description = "BigQuery dataset ID"
  value       = google_bigquery_dataset.chameleon.dataset_id
}

output "bigquery_raw_users_table_id" {
  description = "BigQuery raw users ingestion table full ID (dataset.table)"
  value       = "${google_bigquery_dataset.chameleon.dataset_id}.${google_bigquery_table.raw_users.table_id}"
}

output "bigquery_stg_users_model_id" {
  description = "dbt-owned BigQuery staging users model full ID (dataset.table)"
  value       = "${google_bigquery_dataset.chameleon.dataset_id}.stg_users"
}

output "bigquery_analytics_users_table_id" {
  description = "BigQuery analytics users table full ID (dataset.table)"
  value       = "${google_bigquery_dataset.chameleon.dataset_id}.${google_bigquery_table.analytics_users.table_id}"
}

output "bigquery_compliance_dataset_id" {
  description = "BigQuery compliance dataset ID"
  value       = google_bigquery_dataset.compliance.dataset_id
}

output "bigquery_pii_metadata_registry_table_id" {
  description = "PII metadata registry table full ID (dataset.table)"
  value       = "${google_bigquery_dataset.compliance.dataset_id}.${google_bigquery_table.pii_metadata_registry.table_id}"
}

output "bigquery_ghost_data_findings_table_id" {
  description = "Ghost data findings table full ID (dataset.table)"
  value       = "${google_bigquery_dataset.compliance.dataset_id}.${google_bigquery_table.ghost_data_findings.table_id}"
}

output "warehouse_discovery_project_id" {
  description = "BigQuery project approved for warehouse metadata discovery"
  value       = local.warehouse_discovery_project_id
}

output "warehouse_discovery_dataset_ids" {
  description = "BigQuery dataset IDs approved for warehouse metadata discovery"
  value       = sort(tolist(var.warehouse_discovery_dataset_ids))
}

output "warehouse_discovery_row_sampling_enabled" {
  description = "Whether the data pipeline identity has read access for row sampling on approved discovery datasets"
  value       = var.warehouse_discovery_enable_row_sampling
}

output "gcs_bucket_name" {
  description = "Cloud Storage landing zone bucket name"
  value       = google_storage_bucket.landing_zone.name
}

output "gcs_bucket_url" {
  description = "Cloud Storage bucket URL"
  value       = "gs://${google_storage_bucket.landing_zone.name}"
}

output "service_account_data_pipeline_email" {
  description = "Data pipeline service account email"
  value       = google_service_account.data_pipeline.email
}

output "service_account_bigquery_access_email" {
  description = "BigQuery access service account email"
  value       = google_service_account.bigquery_access.email
}

output "service_account_dbt_email" {
  description = "dbt service account email"
  value       = google_service_account.dbt.email
}

output "service_account_firestore_access_email" {
  description = "Firestore access service account email"
  value       = google_service_account.firestore_access.email
}

output "service_account_key_vault_email" {
  description = "Key Vault microservice service account email"
  value       = google_service_account.key_vault.email
}

output "environment" {
  description = "Deployed environment"
  value       = var.environment
}

output "gcp_region" {
  description = "GCP region"
  value       = var.gcp_region
}

# Cloud KMS Outputs
output "kms_key_ring_name" {
  description = "Regional Cloud KMS key ring name"
  value       = google_kms_key_ring.regional.name
}

output "kms_key_ring_id" {
  description = "Regional Cloud KMS key ring full resource ID"
  value       = google_kms_key_ring.regional.id
}

output "kms_bigquery_key_ring_name" {
  description = "BigQuery Cloud KMS key ring name"
  value       = google_kms_key_ring.bigquery.name
}

output "kms_bigquery_key_ring_id" {
  description = "BigQuery Cloud KMS key ring full resource ID"
  value       = google_kms_key_ring.bigquery.id
}

output "kms_bigquery_location" {
  description = "Cloud KMS location used for BigQuery CMEK"
  value       = local.bigquery_kms_location
}

output "kms_bigquery_key_id" {
  description = "Cloud KMS BigQuery encryption key full resource ID"
  value       = google_kms_crypto_key.bigquery_dataset_key.id
}

output "kms_legacy_bigquery_key_id" {
  description = "Legacy regional Cloud KMS BigQuery key preserved during the Phase 2 migration"
  value       = google_kms_crypto_key.bigquery_key.id
}

output "kms_firestore_key_id" {
  description = "Cloud KMS Firestore encryption key full resource ID"
  value       = google_kms_crypto_key.firestore_key.id
}

output "kms_gcs_key_id" {
  description = "Cloud KMS GCS landing zone encryption key full resource ID"
  value       = google_kms_crypto_key.gcs_key.id
}

output "kms_key_vault_key_id" {
  description = "Cloud KMS Key Vault application key full resource ID"
  value       = google_kms_crypto_key.key_vault_key.id
}

output "kms_certificate_signing_key_id" {
  description = "Cloud KMS asymmetric signing key ID for Certificates of Destruction"
  value       = google_kms_crypto_key.certificate_signing_key.id
}

# Cloud Secret Manager Outputs
output "secret_manager_secret_id" {
  description = "Cloud Secret Manager secret ID (CMEK metadata)"
  value       = google_secret_manager_secret.cmek_master_key.id
}

output "secret_manager_secret_name" {
  description = "Cloud Secret Manager secret name"
  value       = google_secret_manager_secret.cmek_master_key.name
}

output "secret_manager_secret_version" {
  description = "Cloud Secret Manager secret version ID"
  value       = google_secret_manager_secret_version.cmek_master_key_version.version
}

# Audit Logging Outputs
output "audit_log_bucket_name" {
  description = "Cloud Storage bucket that stores exported compliance audit logs"
  value       = google_storage_bucket.audit_logs.name
}

output "audit_log_bucket_url" {
  description = "Cloud Storage URL for the compliance audit log bucket"
  value       = "gs://${google_storage_bucket.audit_logs.name}"
}

output "audit_log_retention_days" {
  description = "Minimum retention period for exported compliance audit logs"
  value       = var.audit_log_retention_days
}

output "audit_log_sink_name" {
  description = "Cloud Logging sink used to export compliance audit logs"
  value       = google_logging_project_sink.compliance_audit_logs.name
}

output "audit_log_sink_writer_identity" {
  description = "Writer identity used by the compliance audit log sink"
  value       = google_logging_project_sink.compliance_audit_logs.writer_identity
}

# Workload Identity Federation Outputs
output "workload_identity_pool_name" {
  description = "Workload Identity Pool resource name for GitHub Actions"
  value       = try(google_iam_workload_identity_pool.github_actions[0].name, null)
}

output "workload_identity_pool_id" {
  description = "Workload Identity Pool ID"
  value       = try(google_iam_workload_identity_pool.github_actions[0].workload_identity_pool_id, null)
}

output "workload_identity_provider_name" {
  description = "Workload Identity Provider (GitHub OIDC) resource name"
  value       = try(google_iam_workload_identity_pool_provider.github_provider[0].name, null)
}

output "service_account_github_actions_dev_email" {
  description = "GitHub Actions service account email (dev environment)"
  value       = try(google_service_account.github_actions_dev[0].email, null)
}

output "service_account_github_actions_prod_email" {
  description = "GitHub Actions service account email (prod environment)"
  value       = try(google_service_account.github_actions_prod[0].email, null)
}

output "service_account_key_vault_deployer_email" {
  description = "GitHub Actions deploy service account email for the Key Vault app"
  value       = google_service_account.key_vault_deployer.email
}

output "service_account_console_deployer_email" {
  description = "GitHub Actions deploy service account email for the console app"
  value       = google_service_account.console_deployer.email
}

output "key_vault_artifact_repository" {
  description = "Artifact Registry repository for Key Vault Docker images"
  value       = google_artifact_registry_repository.key_vault.name
}

output "key_vault_artifact_repository_url" {
  description = "Docker repository URL prefix for Key Vault images"
  value       = "${var.gcp_region}-docker.pkg.dev/${var.gcp_project_id}/${google_artifact_registry_repository.key_vault.repository_id}"
}

output "key_vault_cloud_run_service_name" {
  description = "Cloud Run service name for Key Vault"
  value       = google_cloud_run_v2_service.key_vault.name
}

output "key_vault_cloud_run_service_uri" {
  description = "External HTTPS URI for the Key Vault Cloud Run service"
  value       = google_cloud_run_v2_service.key_vault.uri
}

output "console_cloud_run_url" {
  description = "External HTTPS URL for the console Cloud Run service"
  value       = google_cloud_run_v2_service.console.uri
}

output "key_vault_cloud_run_ingress" {
  description = "Cloud Run ingress policy for the Key Vault service"
  value       = google_cloud_run_v2_service.key_vault.ingress
}

output "key_vault_cloud_run_requires_iam_invoker" {
  description = "Whether Key Vault requires IAM-authenticated invocation"
  value       = !var.key_vault_allow_unauthenticated
}

output "github_actions_dev_identity_provider" {
  description = "Full identity provider resource name for GitHub Actions dev environment"
  value       = try(google_iam_workload_identity_pool_provider.github_provider[0].name, null)
}

output "console_password" {
  description = "Generated console access-gate password (CONSOLE_PASSWORD). Always present — this secret has no manual-management precedent to preserve."
  sensitive   = true
  value       = random_password.console_password.result
}

output "vault_api_key_generated" {
  description = "Generated vault-api-key value, when auto_generate_secrets is true (new instances). Null for legacy dev/prod, which manage this secret manually."
  sensitive   = true
  value       = local.auto_generate_secrets ? random_password.vault_api_key[0].result : null
}

output "pii_registry_write_token_generated" {
  description = "Generated pii-registry-write-token value, when auto_generate_secrets is true (new instances). Null for legacy dev/prod, which manage this secret manually."
  sensitive   = true
  value       = local.auto_generate_secrets ? random_password.pii_registry_write_token[0].result : null
}

output "tenant_id" {
  description = "The resolved tenant_id this deployment's console and data-pipelines worker actually share (local.tenant_id in main.tf -- coalesce(var.tenant_id, \"default-tenant\")). Lets the provisioner report the real value back to chameleon-onboarding instead of it assuming the default, which was silently wrong whenever var.tenant_id had been overridden."
  value       = local.tenant_id
}

output "infrastructure_summary" {
  description = "High-level infrastructure summary"
  value = {
    firestore_kms_registry = google_firestore_database.kms_registry.name
    bigquery_dataset       = google_bigquery_dataset.chameleon.dataset_id
    gcs_bucket             = google_storage_bucket.landing_zone.name
    audit_log_bucket       = google_storage_bucket.audit_logs.name
    regional_kms_key_ring  = google_kms_key_ring.regional.name
    bigquery_kms_key_ring  = google_kms_key_ring.bigquery.name
    key_vault_cloud_run    = google_cloud_run_v2_service.key_vault.name
    key_vault_artifacts    = google_artifact_registry_repository.key_vault.repository_id
    environment            = var.environment
    region                 = var.gcp_region
  }
}
