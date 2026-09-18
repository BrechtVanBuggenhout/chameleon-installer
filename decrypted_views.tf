# Decentralized decrypted views: customer-declared BigQuery Authorized Views
# that live-decrypt PII at query time (never at declaration time -- SQL
# views don't execute until queried), via a BigQuery Remote Function calling
# back into Key Vault. Nothing is ever written to BigQuery storage, so the
# existing crypto-shred mechanism (destroying a user's DEK) is sufficient on
# its own -- no new deletion-cascade wiring needed. Kept in a dataset never
# scanned by chameleon_pii's pii_discovery, so it's structurally invisible
# to dbt by construction, not by allowlist exception.
#
# All resources here are gated behind var.enable_decrypted_views and use
# count = var.enable_decrypted_views ? 1 : 0 rather than for_each, matching
# this file's own single-instance-per-deployment shape (one dataset, one
# connection, one routine).

locals {
  # Referenced both by the routine resource below and by the Cloud Run env
  # var wiring in key_vault.tf. Kept as a literal, not
  # google_bigquery_routine.batch_decrypt[0].routine_id, because the routine
  # depends on google_cloud_run_v2_service.key_vault.uri (see
  # remote_function_options.endpoint below) -- referencing the routine
  # resource from key_vault.tf's env block would close that into a real
  # dependency cycle, the same class of problem PII_INGESTOR_WORKER_SERVICE_NAME
  # already works around in key_vault.tf.
  decrypted_views_batch_decrypt_routine_id = "chameleon_batch_decrypt"

  # The identity terraform-apply.yml actually runs as for this environment.
  # The first live apply of chameleon_authorizes_decrypted_views below
  # failed with a 403 on bigquery.datasets.update against a dataset's own
  # legacy access[] array, despite roles/editor -- true at the time, but
  # neither dev's nor prod's GHA deploy identity has held roles/editor
  # since 2026-08-31 (see docs/gha-permissions.md). Confirmed via
  # `gcloud iam roles describe roles/bigquery.admin` that the scoped-down
  # role list's roles/bigquery.admin grant DOES include
  # bigquery.datasets.update -- so the narrow dataOwner grant below is
  # likely redundant with it today. Left in place rather than removed
  # here: that would need a real terraform plan/apply to verify safely,
  # out of scope for this comment fix. null-safe via try() since these WIF
  # identities only exist when enable_terraform_github_actions_identities
  # is on.
  terraform_deployer_email = (
    var.environment == "dev"
    ? try(google_service_account.github_actions_dev[0].email, null)
    : try(google_service_account.github_actions_prod[0].email, null)
  )
}

# Separate dataset, not a label on an existing one: checked pii_vault first
# (the closest existing "Chameleon-owned table in the customer's warehouse")
# and it rides in the same dataset as dbt's own tables, distinguished only
# by a label -- that would make this dataset scannable-by-default and
# require an active allowlist exception, which the whole point of this
# feature is to avoid. Follows the lineage/compliance precedent instead:
# each gets its own google_bigquery_dataset resource.
resource "google_bigquery_dataset" "decrypted_views" {
  count = var.enable_decrypted_views ? 1 : 0

  dataset_id    = "decrypted_views"
  friendly_name = "Chameleon Decrypted Views"
  description   = "Customer-declared BigQuery Authorized Views that live-decrypt PII at query time. Deliberately outside dbt's pii_discovery scan scope -- nothing here is ever materialized."
  location      = var.bigquery_location

  default_encryption_configuration {
    kms_key_name = google_kms_crypto_key.bigquery_dataset_key.id
  }

  labels = merge(var.labels, {
    environment = var.environment
    component   = "decrypted-views"
  })

  # Explicit ACL, replacing BigQuery's create-time default of OWNER/WRITER/
  # READER -> the projectOwners/projectWriters/projectReaders special
  # groups. Without this, ANY principal holding the basic roles/owner or
  # roles/editor role at the PROJECT level -- not just something scoped to
  # this dataset -- already gets direct query access to every declared
  # decrypted view via that legacy default, completely bypassing the
  # per-view consumerServiceAccount-only grant decrypted-view-service.ts
  # otherwise applies carefully (see grantViewerOnView). Confirmed live
  # against both dev and prod via `bq show`: that default ACL was present
  # on both, unnoticed, since this resource never set `access` before.
  #
  # Key Vault's own runtime SA is the only principal that legitimately
  # needs dataset-level access (CREATE/DROP VIEW DDL, per-view IAM grants
  # -- see decrypted_views_operator below); moved here from what used to be
  # a separate google_bigquery_dataset_iam_member resource, since that
  # resource and this field manage the exact same underlying access list --
  # leaving both in place would have Terraform fight itself on every apply,
  # each one undoing the other's entry.
  #
  # Deliberately does NOT list any consumerServiceAccount here: per-view
  # consumers are granted at the TABLE level only (grantViewerOnView), so
  # a dataset-level entry for one would give it access to every view in
  # this dataset, not just its own -- exactly the blast radius this
  # feature exists to avoid.
  access {
    role          = google_project_iam_custom_role.decrypted_views_operator[0].name
    user_by_email = google_service_account.key_vault.email
  }

  # Required, not optional: a dataset ACL update via this field is a full
  # replacement, and the BigQuery API rejects one with no direct OWNER/
  # roles/bigquery.dataOwner entry ("Dataset policy update failed (No
  # owners specified)") -- confirmed live, this resource failed to apply
  # without it. The deploy identity is the right (and only legitimate)
  # owner here: still a single service account, not a special group, so it
  # doesn't reopen the project-Owner/Editor bypass this change exists to
  # close -- same pattern as terraform_deployer_chameleon_owner above for
  # the CHAMELEON dataset.
  access {
    role          = "OWNER"
    user_by_email = local.terraform_deployer_email
  }

  depends_on = [
    google_project_service.bigquery,
    google_kms_crypto_key_iam_member.bigquery_service_agent_kms
  ]
}

# google_bigquery_dataset_access (below) writes to the chameleon dataset's
# own legacy access[] array, which needs bigquery.dataOwner-level rights.
# Originally justified against roles/editor (which didn't cover it); the
# GHA deploy identity hasn't held roles/editor since 2026-08-31 (see
# docs/gha-permissions.md), and its current roles/bigquery.admin grant DOES
# cover bigquery.datasets.update (confirmed via `gcloud iam roles describe`)
# -- this narrow grant is likely now redundant with it, left in place
# pending a real terraform plan/apply to verify removing it is safe.
resource "google_bigquery_dataset_iam_member" "terraform_deployer_chameleon_owner" {
  count = (var.enable_decrypted_views && local.terraform_deployer_email != null) ? 1 : 0

  dataset_id = google_bigquery_dataset.chameleon.dataset_id
  role       = "roles/bigquery.dataOwner"
  member     = "serviceAccount:${local.terraform_deployer_email}"
}

# google_bigquery_routine.batch_decrypt (below) needs
# bigquery.connections.delegate on the connection it references.
# Originally justified against roles/editor (creating the connection
# succeeded under it, but referencing it from a routine 403'd separately);
# the GHA deploy identity hasn't held roles/editor since 2026-08-31 (see
# docs/gha-permissions.md), and its current roles/bigquery.admin grant DOES
# cover bigquery.connections.delegate (confirmed via
# `gcloud iam roles describe`) -- this narrow grant is likely now redundant
# with it, left in place pending a real terraform plan/apply to verify
# removing it is safe.
resource "google_bigquery_connection_iam_member" "terraform_deployer_connection_admin" {
  count = (var.enable_decrypted_views && local.terraform_deployer_email != null) ? 1 : 0

  project       = var.gcp_project_id
  location      = var.bigquery_location
  connection_id = google_bigquery_connection.decrypted_views[0].connection_id
  role          = "roles/bigquery.connectionAdmin"
  member        = "serviceAccount:${local.terraform_deployer_email}"
}

# IAM changes are eventually consistent -- depends_on only orders the API
# calls, it doesn't wait for propagation. The first live apply hit exactly
# this: both grants above succeeded, but the very next resource in the same
# apply still got a 403 because the permission hadn't propagated yet on
# Google's side. A short, cheap wait (no GCP API calls of its own) closes
# that gap; every downstream resource that actually needs these grants
# depends on this instead of the raw IAM resources directly.
resource "time_sleep" "wait_for_iam_propagation" {
  count = (var.enable_decrypted_views && local.terraform_deployer_email != null) ? 1 : 0

  create_duration = "45s"

  depends_on = [
    google_bigquery_dataset_iam_member.terraform_deployer_chameleon_owner,
    google_bigquery_connection_iam_member.terraform_deployer_connection_admin,
  ]
}

# Key Vault's own runtime SA creates each per-declaration view
# (decrypted-view-service.ts's dataset.createTable) referencing the remote
# function backed by this connection -- BigQuery validates
# bigquery.connections.use on the connection at CREATE VIEW time, not just
# at query time. Not covered by decrypted_views_operator below, which is a
# dataset-scoped tables-only custom role. Caught live while declaring a
# real view: "Access Denied ... does not have bigquery.connections.use
# permission for connection ...".
resource "google_bigquery_connection_iam_member" "key_vault_connection_user" {
  count = var.enable_decrypted_views ? 1 : 0

  project       = var.gcp_project_id
  location      = var.bigquery_location
  connection_id = google_bigquery_connection.decrypted_views[0].connection_id
  role          = "roles/bigquery.connectionUser"
  member        = "serviceAccount:${google_service_account.key_vault.email}"

  depends_on = [
    google_bigquery_connection_iam_member.terraform_deployer_connection_admin,
    time_sleep.wait_for_iam_propagation,
  ]
}

# One-time, infra-level authorization: lets any view living in
# decrypted_views read from the chameleon dataset (where the actual PII
# ciphertext / mart tables live) without the querying identity needing
# direct grants there. Authorizes the whole dataset as a view-source
# consumer, not one view at a time -- every future per-declaration view
# just works, no per-declaration Terraform change needed.
resource "google_bigquery_dataset_access" "chameleon_authorizes_decrypted_views" {
  count = var.enable_decrypted_views ? 1 : 0

  depends_on = [
    google_bigquery_dataset_iam_member.terraform_deployer_chameleon_owner,
    time_sleep.wait_for_iam_propagation,
  ]

  dataset_id = google_bigquery_dataset.chameleon.dataset_id
  project    = var.gcp_project_id

  dataset {
    dataset {
      dataset_id = google_bigquery_dataset.decrypted_views[0].dataset_id
      project_id = var.gcp_project_id
    }
    target_types = ["VIEWS"]
  }
}

# BigQuery calls the remote function's backing endpoint (Key Vault's
# /internal/decrypted-views/batch-decrypt) using this connection's own
# auto-provisioned service account, sending a Google-signed OIDC token --
# the same mechanism Cloud Run IAM invoker already validates elsewhere in
# this repo (see key_vault_self_invoker). cloud_resource {} is empty on
# purpose: it's what tells the provider to auto-create that service
# account, there's nothing else to configure for this connection type.
resource "google_bigquery_connection" "decrypted_views" {
  count = var.enable_decrypted_views ? 1 : 0

  connection_id = "decrypted-views-${local.instance_short}"
  location      = var.bigquery_location
  friendly_name = "Chameleon Decrypted Views Remote Function Connection"
  description   = "Connects decrypted-view Remote Functions to Key Vault's batch-decrypt endpoint"

  cloud_resource {}

  depends_on = [google_project_service.bigquery]

  # key_vault_allow_unauthenticated is a real, already-true flag on
  # Chameleon's own dev/prod -- the Vercel-hosted console and local dev both
  # rely on public Cloud Run ingress + the app-level VAULT_API_KEY, not
  # Cloud Run IAM (see dev.tfvars). This resource originally hard-required
  # that flag be false before enabling decrypted views, on the theory that
  # Cloud Run IAM should be a second, independent layer on top of the
  # batch-decrypt route's own auth.
  #
  # Deliberately relaxed (2026-08-02): the route's own ID-token check
  # (decrypted-views-decrypt.ts's verifyCaller) is already a real,
  # cryptographically sound gate on its own -- it verifies a Google-signed
  # ID token against the exact connection SA's email, which nobody can
  # forge without IAM access to impersonate that SA. Locking Cloud Run IAM
  # down on top of that would require giving the Vercel-hosted console a
  # GCP identity it doesn't have today (a stored key or Workload Identity
  # Federation, both real infra work) purely for a second layer whose first
  # layer already holds on its own. Revisit if that console gains a GCP
  # identity anyway for other reasons.
  lifecycle {
    # Every decrypted view is built on top of the central pii_vault table
    # (see decrypted-view-service.ts) -- never a customer-supplied resource
    # id. That table only exists when enable_pii_ingestor_worker is on
    # (pii_vault.tf), so without this precondition PII_VAULT_RESOURCE_ID
    # would point key-vault at a table that was never created.
    precondition {
      condition     = var.enable_pii_ingestor_worker
      error_message = "enable_decrypted_views requires enable_pii_ingestor_worker = true -- pii_vault (the table every decrypted view sources from) only exists when that flag is on."
    }
  }
}

# Least-privilege role for Key Vault's own CREATE VIEW / DROP VIEW DDL and
# per-view IAM grants (application code in decrypted-view-service.ts, not
# Terraform -- these are dynamically named, end-user-triggered resources
# Terraform can't reconcile). Bound at the dataset level via the `access`
# block on google_bigquery_dataset.decrypted_views above, not project-wide
# -- Key Vault's own SA should not be able to touch tables outside this one
# dataset. (Previously a separate google_bigquery_dataset_iam_member
# resource here; folded into the dataset's own `access` block once that
# field needed to be set anyway to drop the default projectOwners/Writers/
# Readers ACL -- keeping both would have managed the same underlying list
# from two places.)
resource "google_project_iam_custom_role" "decrypted_views_operator" {
  count = var.enable_decrypted_views ? 1 : 0

  role_id     = "decryptedViewsOperator_${local.instance_short}"
  title       = "Decrypted Views Operator (${local.instance_name})"
  description = "Minimum BigQuery permissions to declare/revoke decrypted views and grant per-view IAM"
  permissions = [
    "bigquery.datasets.get",
    "bigquery.tables.create",
    "bigquery.tables.update",
    "bigquery.tables.delete",
    "bigquery.tables.get",
    "bigquery.tables.getIamPolicy",
    "bigquery.tables.setIamPolicy",
  ]
}

# The connection's own service account only needs to be able to call Key
# Vault's Cloud Run service -- it never touches BigQuery datasets directly,
# and never gets any role broader than run.invoker on this one service.
resource "google_cloud_run_v2_service_iam_member" "decrypted_views_connection_invoker" {
  count = var.enable_decrypted_views ? 1 : 0

  project  = var.gcp_project_id
  location = google_cloud_run_v2_service.key_vault.location
  name     = google_cloud_run_v2_service.key_vault.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_bigquery_connection.decrypted_views[0].cloud_resource[0].service_account_id}"
}

# The Remote Function itself: a one-time DDL registration, not something
# created per-declaration. decrypted-view-service.ts's generated view SQL
# calls this function by its fully qualified name (see
# DECRYPTED_VIEWS_BATCH_DECRYPT_FUNCTION_REF in key_vault.tf's env block).
# definition_body is empty because REMOTE routines have no SQL body -- all
# the real logic lives behind remote_function_options.endpoint.
resource "google_bigquery_routine" "batch_decrypt" {
  count = var.enable_decrypted_views ? 1 : 0

  dataset_id      = google_bigquery_dataset.decrypted_views[0].dataset_id
  routine_id      = local.decrypted_views_batch_decrypt_routine_id
  routine_type    = "SCALAR_FUNCTION"
  definition_body = ""
  return_type     = "{\"typeKind\" : \"STRING\"}"

  arguments {
    name      = "encrypted_value"
    data_type = "{\"typeKind\" : \"STRING\"}"
  }
  arguments {
    name      = "user_id"
    data_type = "{\"typeKind\" : \"STRING\"}"
  }
  arguments {
    name      = "tenant_id"
    data_type = "{\"typeKind\" : \"STRING\"}"
  }

  remote_function_options {
    endpoint = "${google_cloud_run_v2_service.key_vault.uri}/internal/decrypted-views/batch-decrypt"
    # NOT the short project.location.connection_id form BigQuery's own SQL
    # DDL accepts -- the Terraform provider's remote_function_options.connection
    # field requires the fully-qualified resource path. Confirmed for real:
    # the short form 400'd on first live apply ("Connection name should
    # conform to the pattern: projects/.../locations/.../connections/...").
    connection = "projects/${var.gcp_project_id}/locations/${var.bigquery_location}/connections/${google_bigquery_connection.decrypted_views[0].connection_id}"
    # Google recommends starting low and tuning against real
    # Firestore-lookup + KMS-unwrap latency once this is exercised for
    # real -- not a final number, a conservative starting point.
    max_batching_rows = "50"
  }

  depends_on = [
    google_bigquery_connection.decrypted_views,
    google_cloud_run_v2_service_iam_member.decrypted_views_connection_invoker,
    google_bigquery_connection_iam_member.terraform_deployer_connection_admin,
    time_sleep.wait_for_iam_propagation,
  ]
}
