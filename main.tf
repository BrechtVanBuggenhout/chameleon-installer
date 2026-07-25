terraform {
  # >= 1.9 for cross-variable validation (key_vault_auth_bypass_enabled's
  # validation block references var.environment). CI is pinned to 1.9.0.
  required_version = ">= 1.9"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

moved {
  from = google_kms_key_ring.chameleon
  to   = google_kms_key_ring.regional
}

provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
}

provider "google-beta" {
  project = var.gcp_project_id
  region  = var.gcp_region
}

locals {
  bigquery_kms_location = upper(var.bigquery_location) == "US" ? "us" : upper(var.bigquery_location) == "EU" ? "europe" : lower(var.bigquery_location)

  # instance_name is the free-form per-deployment identifier used for
  # naming; it defaults to var.environment so existing dev/prod deployments
  # (which never set var.instance_name) produce byte-identical resource
  # names to before this variable existed.
  instance_name = coalesce(var.instance_name, var.environment)
  # Legacy Chameleon-owned deployments keep their literal "dev"/"prod"
  # suffix (guarantees zero renames of already-applied resources). GCP
  # service-account account_id (and the KMS operator custom role_id, which
  # additionally disallows hyphens) has a hard 30-character ceiling that a
  # free-form customer instance_name could easily overflow, so any other
  # instance gets a short, deterministic, hyphen-free hash instead. Safe
  # under the one-instance-per-GCP-project deployment model: two different
  # instance_names never coexist in the same project's IAM namespace.
  is_legacy_instance = contains(["dev", "prod"], local.instance_name)
  instance_short     = local.is_legacy_instance ? local.instance_name : substr(md5(local.instance_name), 0, 4)

  # Chameleon's own dev/prod set secret values manually today (see the
  # `removed` blocks in key_vault.tf) and must keep doing so unless
  # explicitly opted in; any new instance gets auto-generated values by
  # default so onboarding needs no manual Secret Manager step.
  auto_generate_secrets = coalesce(var.auto_generate_secrets, !local.is_legacy_instance)

  # Shared tenant identifier for this instance — the console (NEXT_PUBLIC_TENANT_ID)
  # and the data-pipelines worker (TENANT_ID) must agree, or the console can
  # create/destroy keys correctly but can never look up the resulting
  # certificate (wrong tenant = 404, silently masked by its own demo-fixture
  # fallback).
  #
  # Defaults to the literal "default-tenant" for every deployment, including
  # BYOC/managed-dedicated — NOT instance_name. Key Vault's CloudKMSClient
  # (src/gcp/cloud-kms.ts) treats "default-tenant" as a sentinel for "use the
  # static per-instance KMS key"; any other tenant string makes it silently
  # provision a *dynamic, auto-created* per-tenant KMS key instead (a
  # vestigial true-multi-tenant codepath from before the single-tenant-per-
  # deployment architecture decision). The data-pipelines worker only ever
  # unwraps DEKs with its one static KMS_KEY_PATH, so any tenant other than
  # "default-tenant" makes ingestion fail 100% of the time with
  # INDECIPHERABLE_CIPHERTEXT_FOR_CRYPTOKEY. Since every BYOC/managed-
  # dedicated instance is already fully isolated at the infra level (own
  # project, own KMS keyring, own everything), there's no benefit to varying
  # this per instance — only var.tenant_id can override it, and shouldn't
  # without also addressing the KMS codepath above.
  tenant_id = coalesce(var.tenant_id, "default-tenant")

  audit_log_bucket_name    = coalesce(var.audit_log_bucket_name, "${var.app_name}-audit-logs-${local.instance_name}-${var.gcp_project_id}")
  bigquery_rls_admin_email = var.bigquery_rls_admin_email
  warehouse_discovery_project_id = coalesce(
    var.warehouse_discovery_project_id,
    var.gcp_project_id
  )
  audit_log_services = toset([
    "bigquery.googleapis.com",
    "cloudkms.googleapis.com",
    "run.googleapis.com",
    "datastore.googleapis.com",
    "iam.googleapis.com",
    "secretmanager.googleapis.com",
    "storage.googleapis.com",
    "pubsub.googleapis.com"
  ])

  tenant_access_map_members = distinct(concat(
    var.tenant_access_map_user_members,
    [local.bigquery_rls_admin_email],
    [
      google_service_account.key_vault.email,
      google_service_account.data_pipeline.email,
      google_service_account.pii_ingestor_worker.email,
      google_service_account.bigquery_access.email,
      google_service_account.dbt.email
    ]
  ))

  tenant_access_map_rows = flatten([
    for tenant_id in var.tenant_access_map_tenant_ids : [
      for member in local.tenant_access_map_members : {
        tenant_id         = tenant_id
        authorized_member = member
        tenant_id_sql     = jsonencode(tenant_id)
        authorized_sql    = jsonencode(member)
      }
    ]
  ])

  tenant_access_map_seed_structs = join(",\n          ", [
    for row in local.tenant_access_map_rows :
    "STRUCT(${row.tenant_id_sql} AS tenant_id, ${row.authorized_sql} AS authorized_member)"
  ])

  bigquery_rls_policy_grantees = distinct(concat(
    [
      for member in distinct(concat(var.tenant_access_map_user_members, [local.bigquery_rls_admin_email])) :
      startswith(member, "user:") || startswith(member, "group:") || startswith(member, "domain:") || startswith(member, "serviceAccount:") || member == "allAuthenticatedUsers" ? member : "user:${member}"
    ],
    [
      "serviceAccount:${google_service_account.key_vault.email}",
      "serviceAccount:${google_service_account.data_pipeline.email}",
      "serviceAccount:${google_service_account.pii_ingestor_worker.email}",
      "serviceAccount:${google_service_account.dbt.email}",
      "serviceAccount:${google_service_account.bigquery_access.email}"
    ]
  ))
}

data "google_project" "current" {
  project_id = var.gcp_project_id

  depends_on = [google_project_service.cloudresourcemanager]
}

data "google_storage_project_service_account" "gcs" {
  project = var.gcp_project_id

  depends_on = [google_project_service.storage]
}

data "google_bigquery_default_service_account" "bq" {
  project = var.gcp_project_id

  depends_on = [google_project_service.bigquery]
}
