# IAM for chameleon-key-vault's SourceRedactionService (REDACT_IN_PLACE and
# SHADOW_COPY -- see that repo's own docs for the full feature). Both
# strategies need Key Vault's runtime SA to write to whatever table a
# customer manually declares -- REDACT_IN_PLACE runs a real UPDATE nulling
# out declared PII columns, SHADOW_COPY creates/drops a "{table}_deidentified"
# view alongside the source table.
#
# Project-scoped, not scoped to a single dataset: mirrors the exact same
# reasoning already established for key_vault_bigquery_metadata_viewer
# (key_vault.tf) -- a manually-declared resource can live in any dataset in
# this project, not just Chameleon's own `chameleon` dataset, and which
# dataset that is is only known at declare time (via the console's Declare
# panel), not at Terraform-apply time. Terraform has no way to scope this
# any narrower without breaking real declarations in other datasets.
#
# A narrow custom role, not roles/bigquery.dataEditor -- exactly the
# permissions SourceRedactionService's code actually calls (verified against
# its BigQuery client usage: createQueryJob for the UPDATE, createTable/
# table().delete() for the shadow-copy view), matching this repo's existing
# least-privilege convention (see decrypted_views.tf's decryptedViewsOperator
# custom role for the same pattern).
#
# bigquery.tables.getData is required alongside updateData: REDACT_IN_PLACE's
# UPDATE has a real WHERE clause (userId/tenantId), and BigQuery must read
# matching rows to evaluate it before writing NULLs -- get (metadata only)
# does not cover this. Missing this permission produces a real, confirmed
# "Access Denied ... or perhaps it does not exist" failure on the UPDATE job
# even though updateData is already granted (found via a live customer
# failure 2026-08-16 -- see source-redaction-service.ts's redactOne()).
#
# Limitation, stated plainly: this only covers tables within THIS GCP
# project. A resource declared in a genuinely separate/external project (a
# real BYOC customer's own project, distinct from wherever Key Vault itself
# runs) needs this same grant applied there too, out of band -- Terraform
# here has no way to know about a project it was never told to manage.
resource "google_project_iam_custom_role" "source_redaction_operator" {
  role_id     = "sourceRedactionOperator_${local.instance_short}"
  title       = "Source Redaction Operator (${local.instance_name})"
  description = "Minimum BigQuery permissions for Key Vault to run REDACT_IN_PLACE or maintain a SHADOW_COPY view on a manually-declared resource"
  permissions = [
    "bigquery.tables.get",
    "bigquery.tables.getData",
    "bigquery.tables.create",
    "bigquery.tables.delete",
    "bigquery.tables.updateData",
  ]
}

resource "google_project_iam_member" "key_vault_source_redaction_operator" {
  project = var.gcp_project_id
  role    = google_project_iam_custom_role.source_redaction_operator.name
  member  = "serviceAccount:${google_service_account.key_vault.email}"
}

# Same custom role, granted in var.additional_source_projects too -- a
# custom role's fully-qualified name (.name below) can be referenced in an
# IAM binding on a different project than the one that defines it, so this
# doesn't need to redefine the role per-project. Resolves the "only covers
# THIS GCP project" limitation stated in this file's own comment above, for
# customers who declare a resource in more than one of their own projects
# but still want it served by this one Key Vault deployment/image -- see
# variables.tf's additional_source_projects for the full reasoning.
resource "google_project_iam_member" "key_vault_source_redaction_operator_additional" {
  for_each = var.additional_source_projects
  project  = each.value
  role     = google_project_iam_custom_role.source_redaction_operator.name
  member   = "serviceAccount:${google_service_account.key_vault.email}"
}
