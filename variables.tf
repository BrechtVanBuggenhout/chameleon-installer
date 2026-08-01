variable "gcp_project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "gcp_region" {
  description = "GCP region for resources"
  type        = string
  default     = "us-central1"
}

variable "environment" {
  description = "Deployment tier (dev or prod). Controls behavior only — scaling, deletion protection, log level — not resource naming; see instance_name for that."
  type        = string
  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "Environment must be 'dev' or 'prod'."
  }
}

variable "instance_name" {
  description = "Free-form identifier for this deployment instance (e.g. a customer slug for BYOC/managed-dedicated). Used for resource naming. Defaults to var.environment so Chameleon's own dev/prod deployments are unaffected."
  type        = string
  default     = null

  validation {
    condition     = var.instance_name == null || can(regex("^[a-z][a-z0-9-]{1,18}[a-z0-9]$", var.instance_name))
    error_message = "instance_name must be 3-20 characters, lowercase alphanumeric and hyphens, starting and ending with an alphanumeric character."
  }
}

variable "tenant_id" {
  description = "Tenant identifier shared by the console (NEXT_PUBLIC_TENANT_ID) and the data-pipelines worker (TENANT_ID). Defaults to 'default-tenant' for every deployment — do not override without also addressing Key Vault's per-tenant dynamic KMS key codepath (see tenant_id in main.tf's locals)."
  type        = string
  default     = null
}

variable "bigquery_rls_admin_email" {
  description = "Email of the principal granted admin access under BigQuery row-level security. Required — no default, since the previous hardcoded value was Chameleon's own founder email."
  type        = string
}

variable "key_vault_auth_bypass_enabled" {
  description = "Runs Key Vault with NO API-key authentication (VAULT_API_KEY left unset), so a local/dev instance can be exercised end-to-end without setting up auth. Explicit opt-in, default false even on dev tier — this never changes Chameleon's own dev deployment unless deliberately set. Structurally cannot apply to environment=prod: see the validation block."
  type        = bool
  default     = false

  validation {
    condition     = !var.key_vault_auth_bypass_enabled || var.environment == "dev"
    error_message = "key_vault_auth_bypass_enabled can only be true when environment is 'dev' — a prod-tier instance can never run with authentication disabled, even by mistake."
  }
}

variable "auto_generate_secrets" {
  description = "Whether Terraform should generate and populate values for vault-api-key and pii-registry-write-token (vs. leaving them to be set manually, as Chameleon's own dev/prod already do today). Defaults to true for any new instance and false for legacy dev/prod, so existing manually-managed secret values are never touched."
  type        = bool
  default     = null
}

variable "app_name" {
  description = "Application name for resource naming"
  type        = string
  default     = "chameleon"
}

# Firestore Configuration
# NOTE: For this MVP, we use Firestore (free tier: 1GB storage, 50k reads/day, 20k writes/day).
# In production, consider migrating to Cloud SQL (PostgreSQL) for stronger ACID guarantees.
variable "firestore_region" {
  description = "Firestore region (multi-region or single-region)"
  type        = string
  default     = "us-central1"
}

variable "firestore_database_id" {
  description = "Firestore database name/ID for the KMS key registry backend. Defaults to \"(default)\" for backward compatibility with Chameleon's own existing dev/prod deployments, which already use the project's actual default database. Override this for any BYOC deployment into a GCP project that might already have a \"(default)\" Firestore database from something unrelated to Chameleon -- common, since App Engine, Firebase, and prior Firestore usage all auto-provision it. GCP rejects creating a second \"(default)\" database with a 409 (\"please use another database_id\"); any other name works as a real, independent database."
  type        = string
  default     = "(default)"
}

variable "enable_firestore_cmek" {
  description = "Enable CMEK on Firestore database creation. Existing non-CMEK Firestore databases cannot be converted in place."
  type        = bool
  default     = false
}

# BigQuery Configuration
variable "bigquery_dataset_id" {
  description = "BigQuery dataset ID"
  type        = string
}

variable "bigquery_location" {
  description = "BigQuery dataset location"
  type        = string
  default     = "US"
}

variable "lineage_dataset_id" {
  description = "BigQuery dataset ID for the lineage engine"
  type        = string
  default     = "lineage_db"
}

variable "lineage_table_id" {
  description = "BigQuery table ID for lineage events"
  type        = string
  default     = "events"
}

variable "enable_bigquery_row_access_policies" {
  description = "Enable BigQuery row access policies for tenant isolation."
  type        = bool
  default     = true
}

variable "warehouse_discovery_project_id" {
  description = "Project ID that contains BigQuery datasets approved for warehouse metadata discovery. Defaults to gcp_project_id."
  type        = string
  default     = null
}

variable "warehouse_discovery_dataset_ids" {
  description = "Explicit BigQuery dataset IDs that the data pipeline service account may inspect for warehouse metadata discovery."
  type        = set(string)
  default     = []

  validation {
    condition = alltrue([
      for dataset_id in var.warehouse_discovery_dataset_ids :
      length(dataset_id) <= 1024 && can(regex("^[A-Za-z_][A-Za-z0-9_]*$", dataset_id))
    ])
    error_message = "warehouse_discovery_dataset_ids must contain valid BigQuery dataset IDs."
  }
}

variable "warehouse_discovery_enable_row_sampling" {
  description = "Grant read access on approved discovery datasets for sampled ghost-data scanning. Keep false for metadata-only discovery."
  type        = bool
  default     = false
}

variable "tenant_access_map_tenant_ids" {
  description = "Tenant IDs to seed into lineage_db.tenant_access_map for RLS lookups."
  type        = list(string)
  default     = []
}

variable "tenant_access_map_user_members" {
  description = "Bare user emails to seed into lineage_db.tenant_access_map. BigQuery SESSION_USER() returns bare emails, not IAM member strings."
  type        = list(string)
  default     = []
}

# Cloud Storage Configuration
variable "gcs_bucket_name" {
  description = "GCS landing zone bucket name"
  type        = string
}

variable "gcs_storage_class" {
  description = "GCS bucket storage class"
  type        = string
  default     = "STANDARD"
}

# IAM & Service Accounts
variable "service_account_roles" {
  description = "IAM roles to assign to service accounts"
  type        = list(string)
  default = [
    "roles/bigquery.dataEditor",
    "roles/bigquery.jobUser",
    "roles/storage.objectAdmin",
    "roles/cloudsql.client"
  ]
}

# Labels for resource organization
variable "labels" {
  description = "Common labels applied to all resources"
  type        = map(string)
  default     = {}
}

# Cloud KMS Configuration
variable "kms_region" {
  description = "Region for Cloud KMS key ring"
  type        = string
  default     = "us-central1"
}

variable "kms_rotation_period" {
  description = "Rotation period for KMS keys in seconds (default: 90 days)"
  type        = string
  default     = "7776000s"
}

# Cloud Secret Manager Configuration
variable "secret_manager_replication" {
  description = "Replication strategy for secrets (automatic or user_managed)"
  type        = string
  default     = "automatic"
}

# Audit Logging Configuration
variable "audit_log_bucket_name" {
  description = "Optional globally unique GCS bucket name for exported audit logs. Defaults to chameleon-audit-logs-<environment>-<project_id>."
  type        = string
  default     = null
}

variable "audit_log_retention_days" {
  description = "Minimum number of days to retain exported audit logs in the audit evidence bucket."
  type        = number
  default     = 2555

  validation {
    condition     = var.audit_log_retention_days >= 1
    error_message = "Audit log retention must be at least 1 day."
  }
}

variable "audit_log_retention_lock" {
  description = "Whether to lock the GCS retention policy for exported audit logs. Only enable after validating retention requirements because this cannot be undone."
  type        = bool
  default     = false
}

# Workload Identity Federation Configuration
variable "github_repository_owner" {
  description = "GitHub repository owner (organization or user) trusted by the WIF pool's attribute_condition. Required only when enable_workload_identity_federation is true -- empty string is fine (and the default) otherwise. A previous version of this variable defaulted to Chameleon's own GitHub account unconditionally, which would have silently granted Chameleon's CI trust on your project had you ever enabled WIF without overriding it; a later attempt to fix that by dropping the default entirely broke every BYOC signup, since the generated tfvars always sets enable_workload_identity_federation = false but Terraform still requires a value for any variable with no default regardless of which resources actually consume it."
  type        = string
  default     = ""

  validation {
    condition     = var.enable_workload_identity_federation == false || length(var.github_repository_owner) > 0
    error_message = "github_repository_owner is required when enable_workload_identity_federation is true."
  }
}

variable "github_repository_name" {
  description = "GitHub repository name"
  type        = string
  default     = "chameleon-infra-gcp"
}

variable "enable_workload_identity_federation" {
  description = "Enable Workload Identity Federation for GitHub Actions CI/CD"
  type        = bool
  default     = true
}

variable "enable_terraform_github_actions_identities" {
  description = "Create broad Terraform GitHub Actions service accounts and IAM roles. Keep false unless Terraform apply automation is being enabled."
  type        = bool
  default     = false
}

# Key Vault Cloud Run Deployment
variable "key_vault_github_repository_name" {
  description = "GitHub repository name that deploys the Key Vault application"
  type        = string
  default     = "chameleon-key-vault"
}

variable "data_pipeline_github_repository_name" {
  description = "GitHub repository name that deploys the PII Ingestor Worker"
  type        = string
  default     = "chameleon-data-pipelines"
}

variable "console_github_repository_name" {
  description = "GitHub repository name that deploys the console"
  type        = string
  default     = "chameleon-console"
}

variable "key_vault_artifact_repository_id" {
  description = "Artifact Registry Docker repository ID for Key Vault images"
  type        = string
  default     = "key-vault"
}

variable "key_vault_artifact_repository_description" {
  description = "Artifact Registry repository description for Key Vault images"
  type        = string
  default     = "Docker images for the Chameleon Key Vault service"
}

variable "key_vault_artifact_cleanup_keep_count" {
  description = "Minimum number of recent Key Vault container image versions to keep"
  type        = number
  default     = 20
}

variable "key_vault_service_name" {
  description = "Cloud Run service name for the Key Vault application"
  type        = string
  default     = null
}

variable "key_vault_deployer_service_account_id" {
  description = "Optional service account account_id for the Key Vault deploy identity. Must be 6-30 characters."
  type        = string
  default     = null
}

variable "key_vault_container_image" {
  description = "Initial container image for Key Vault Cloud Run. Override with the app image after the first push."
  type        = string
  default     = "us-docker.pkg.dev/cloudrun/container/hello"
}

variable "console_image" {
  description = "Container image for the console Cloud Run service (see Phase 4 / chameleon-console's Dockerfile). Override with a real published tag; the placeholder just lets a fresh apply succeed before the first image push."
  type        = string
  default     = "us-docker.pkg.dev/cloudrun/container/hello"
}

variable "key_vault_artifact_registry_external_readers" {
  description = "IAM members (e.g. 'serviceAccount:key-vault@customer-project.iam.gserviceaccount.com') granted artifactregistry.reader on the Key Vault image repository. Populated per BYOC customer during onboarding so their own project's terraform apply can pull Chameleon-built images without needing their own CI. Empty for managed-dedicated (Chameleon already owns the registry project) and for Chameleon's own dev/prod."
  type        = list(string)
  default     = []
}

variable "data_pipeline_artifact_registry_external_readers" {
  description = "Same as key_vault_artifact_registry_external_readers, for the PII Ingestor Worker image repository."
  type        = list(string)
  default     = []
}

variable "console_artifact_registry_external_readers" {
  description = "Same as key_vault_artifact_registry_external_readers, for the console image repository."
  type        = list(string)
  default     = []
}

variable "key_vault_allow_unauthenticated" {
  description = "Allow public unauthenticated invocation of the Key Vault Cloud Run service"
  type        = bool
  default     = false
}

variable "console_allow_unauthenticated" {
  description = "Allow public unauthenticated invocation of the console Cloud Run service. Defaults true because the console's real access control is its own app-level CONSOLE_PASSWORD gate (proxy.ts), not Cloud Run IAM invoker — a browser can't present a Cloud Run identity token, so leaving this false would make the console unreachable."
  type        = bool
  default     = true
}

variable "key_vault_cloud_run_ingress" {
  description = "Cloud Run ingress policy for Key Vault"
  type        = string
  default     = "INGRESS_TRAFFIC_INTERNAL_ONLY"

  validation {
    condition = contains([
      "INGRESS_TRAFFIC_ALL",
      "INGRESS_TRAFFIC_INTERNAL_ONLY",
      "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
    ], var.key_vault_cloud_run_ingress)
    error_message = "key_vault_cloud_run_ingress must be a valid Cloud Run v2 ingress enum."
  }
}

variable "key_vault_firestore_collection" {
  description = "Firestore collection used by Key Vault for the key registry"
  type        = string
  default     = "key_registry"
}

variable "key_vault_firestore_deletion_request_collection" {
  description = "Firestore collection used by Key Vault for deletion requests"
  type        = string
  default     = "deletion_requests"
}

variable "key_vault_log_level" {
  description = "Log level for the Key Vault Cloud Run service"
  type        = string
  default     = "info"
}

variable "key_vault_use_bundled_seed" {
  description = "Seed the PII registry with Chameleon's own bundled connector-slice example data (src/data/pii-registry.ts). Only Chameleon's own dev/prod instances should enable this — BYOC/managed-dedicated customer deployments must start with an empty registry."
  type        = bool
  default     = false
}

# PII Ingestor Cloud Run Worker Configuration
variable "enable_pii_ingestor_worker" {
  description = "Enable the PII Ingestor Cloud Run worker and its associated resources."
  type        = bool
  default     = false
}

# Decentralized decrypted views (see decrypted_views.tf)
variable "enable_decrypted_views" {
  description = "Enable customer-declared BigQuery Authorized Views that live-decrypt PII at query time via a Remote Function, without ever materializing plaintext. Requires key_vault_allow_unauthenticated = false (enforced by a check block in decrypted_views.tf)."
  type        = bool
  default     = false
}

variable "warehouse_crawl_schedule" {
  description = "Cron schedule (Cloud Scheduler) for the warehouse metadata crawl."
  type        = string
  default     = "0 6 * * *"
}

variable "pii_vault_sync_schedule" {
  description = "Cron schedule (Cloud Scheduler) for the daily PII vault backfill/sync job."
  type        = string
  default     = "0 7 * * *"
}

variable "signing_key_rotation_schedule" {
  description = "Cron schedule (Cloud Scheduler) for rotating the Certificate of Destruction signing key. Old versions are never destroyed, so shortening this only adds versions to the JWKS response, it never breaks previously-issued certificates."
  type        = string
  default     = "0 3 1 */3 *" # Approximately every 90 days -- 1st of every 3rd month, 03:00 UTC
}

variable "enable_pii_audit_mirror" {
  description = "Grant Key Vault dataEditor on the compliance dataset + set PII_AUDIT_DATASET_ID so declarations are mirrored to compliance.pii_metadata_registry. Requires the Terraform identity to own the compliance dataset. Declarations are durable in Firestore regardless; this is an audit-evidence copy."
  type        = bool
  default     = false
}

# All pii_registry_snowflake_*, pii_warehouse_type, and pii_ingestor_snowflake_*
# variables live in snowflake.tf, kept apart from the BigQuery/GCP variables
# in this file.

variable "pii_ingestor_worker_container_image" {
  description = "Container image for the PII Ingestor Cloud Run worker."
  type        = string
  default     = "gcr.io/cloudrun/hello" # Placeholder, replace with actual image
}

variable "pii_ingestor_worker_max_instances" {
  description = "Maximum number of instances for the PII Ingestor Cloud Run worker."
  type        = number
  default     = 10
}

variable "data_plane_url" {
  description = "URL of the PII Ingestor Worker (Data Plane) Cloud Run service. Set explicitly to avoid circular Terraform dependency."
  type        = string
  default     = ""
}
