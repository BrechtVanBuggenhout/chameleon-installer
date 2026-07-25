# All Snowflake-related configuration, kept separate from the BigQuery/GCP
# resources it's an alternative to. Two independent optional features live
# here, both off by default with zero effect on existing deployments:
#
#   1. Key Vault's dbt-fed PII registry/lineage reader (pii_registry_snowflake_*)
#      -- can run alongside BigQuery's own dbt slice, not instead of it.
#   2. The PII Ingestor Worker's landing-warehouse choice (pii_warehouse_type +
#      pii_ingestor_snowflake_*) -- "bigquery" (default) or "snowflake", never both
#      for the same deployment.
#
# The actual env-var wiring for each has to live inside the Cloud Run resource
# it belongs to (Terraform doesn't allow injecting blocks into a resource
# defined in another file) -- see the `dynamic "env"` blocks in key_vault.tf
# (registry reader) and pii_ingestor_worker.tf (ingestion write path). Only
# the variables and secret containers live here.

# --- Registry reader (Key Vault) ---------------------------------------

# Optional Snowflake reader for the chameleon_pii dbt package's registry/lineage
# tables (an alternative or addition to the BigQuery dbt slice). Leave
# pii_registry_snowflake_account null (the default) to disable it entirely --
# Key Vault falls back to BigQuery-only, no behavior change. The password is
# never set here; it's a Secret Manager secret managed like the HubSpot/
# Salesforce API keys.
variable "pii_registry_snowflake_account" {
  description = "Snowflake account identifier for the dbt-fed PII registry slice (e.g. XY12345-AB67890). Null disables the Snowflake registry reader entirely."
  type        = string
  default     = null
}

variable "pii_registry_snowflake_user" {
  description = "Snowflake username for the PII registry reader."
  type        = string
  default     = null
}

variable "pii_registry_snowflake_role" {
  description = "Optional Snowflake role for the PII registry reader."
  type        = string
  default     = null
}

variable "pii_registry_snowflake_warehouse" {
  description = "Snowflake warehouse for the PII registry reader."
  type        = string
  default     = null
}

variable "pii_registry_snowflake_database" {
  description = "Snowflake database holding the chameleon_pii dbt package's tables."
  type        = string
  default     = null
}

variable "pii_registry_snowflake_schema" {
  description = "Snowflake schema holding the chameleon_pii dbt package's tables."
  type        = string
  default     = null
}

# Snowflake password for the optional dbt-fed PII registry reader. Externally
# managed, same as the HubSpot/Salesforce keys in key_vault.tf -- Terraform
# only holds the container; the real value is set via
# `gcloud secrets versions add` when activated.
resource "google_secret_manager_secret" "pii_registry_snowflake_password" {
  secret_id = "pii-registry-snowflake-password-${local.instance_name}"

  replication {
    auto {}
  }

  labels = merge(var.labels, {
    component = "pii-registry"
    purpose   = "snowflake-auth"
  })
}

resource "google_secret_manager_secret_version" "pii_registry_snowflake_password_version" {
  secret      = google_secret_manager_secret.pii_registry_snowflake_password.id
  secret_data = "placeholder-snowflake-password" # Replace with actual password or use external mechanism

  lifecycle { ignore_changes = [secret_data] }
}

resource "google_secret_manager_secret_iam_member" "key_vault_snowflake_secret" {
  secret_id = google_secret_manager_secret.pii_registry_snowflake_password.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.key_vault.email}"
}

# --- Ingestion write path (PII Ingestor Worker) -------------------------

# Selects the PII Ingestor Worker's landing warehouse. "bigquery" (the
# default) is a no-op -- identical to today's behavior, zero Terraform diff.
# "snowflake" requires the pii_ingestor_snowflake_* vars below.
variable "pii_warehouse_type" {
  description = "Landing warehouse for the PII Ingestor Worker's write path: \"bigquery\" (default) or \"snowflake\"."
  type        = string
  default     = "bigquery"
  validation {
    condition     = contains(["bigquery", "snowflake"], var.pii_warehouse_type)
    error_message = "pii_warehouse_type must be \"bigquery\" or \"snowflake\"."
  }
}

variable "pii_ingestor_snowflake_account" {
  description = "Snowflake account identifier for the PII Ingestor Worker's write path. Only used when pii_warehouse_type = \"snowflake\"."
  type        = string
  default     = null
}

variable "pii_ingestor_snowflake_user" {
  description = "Snowflake username for the PII Ingestor Worker's write path."
  type        = string
  default     = null
}

variable "pii_ingestor_snowflake_role" {
  description = "Optional Snowflake role for the PII Ingestor Worker's write path."
  type        = string
  default     = null
}

variable "pii_ingestor_snowflake_warehouse" {
  description = "Snowflake warehouse for the PII Ingestor Worker's write path."
  type        = string
  default     = null
}

variable "pii_ingestor_snowflake_database" {
  description = "Snowflake database the PII Ingestor Worker writes raw_users into."
  type        = string
  default     = null
}

variable "pii_ingestor_snowflake_schema" {
  description = "Snowflake schema the PII Ingestor Worker writes raw_users into."
  type        = string
  default     = null
}

# Snowflake password for the PII Ingestor Worker's write path. Externally
# managed, same convention as the registry-reader secret above -- Terraform
# only holds the container; the real value is set via
# `gcloud secrets versions add` when activated.
resource "google_secret_manager_secret" "pii_ingestor_snowflake_password" {
  count     = var.enable_pii_ingestor_worker ? 1 : 0
  secret_id = "pii-ingestor-snowflake-password-${local.instance_name}"

  replication {
    auto {}
  }

  labels = merge(var.labels, {
    component = "ingestion-worker"
    purpose   = "snowflake-auth"
  })
}

resource "google_secret_manager_secret_version" "pii_ingestor_snowflake_password_version" {
  count       = var.enable_pii_ingestor_worker ? 1 : 0
  secret      = google_secret_manager_secret.pii_ingestor_snowflake_password[0].id
  secret_data = "placeholder-snowflake-password" # Replace with actual password or use external mechanism

  lifecycle { ignore_changes = [secret_data] }
}

resource "google_secret_manager_secret_iam_member" "pii_ingestor_worker_snowflake_secret" {
  count     = var.enable_pii_ingestor_worker ? 1 : 0
  secret_id = google_secret_manager_secret.pii_ingestor_snowflake_password[0].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.pii_ingestor_worker.email}"
}
