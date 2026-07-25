# Installing Chameleon (BYOC / managed-dedicated)

This is the customer-facing install guide: deploy the full Chameleon stack
(Key Vault, the PII ingestor worker, the console) into a GCP project —
either your own (BYOC) or one Chameleon operates on your behalf
(managed-dedicated, same steps, different operator). This guide assumes no
familiarity with this repo.

## What you get

A single, self-contained deployment identified by an `instance_name` you
choose (e.g. your company slug). Nothing is shared with any other
Chameleon deployment: its own encryption keyring, its own Firestore
database, its own BigQuery dataset, its own Cloud Run services.

## Prerequisites

1. A GCP project, created, with billing enabled. You (or whoever runs the
   install) need owner-or-equivalent rights on it — normal for a project
   you already own.
2. `gcloud` CLI installed and authenticated:
   ```bash
   gcloud auth login
   gcloud auth application-default login
   ```
3. Terraform >= 1.9 installed.
4. If you want Chameleon's pre-built container images (the default path —
   no CI of your own required): tell Chameleon your project's runtime
   service account emails once you know them (bootstrap will print them if
   you re-run it, or find them via `terraform state list | grep
   google_service_account` after the first apply) so Chameleon can grant
   `artifactregistry.reader` on its image repositories
   (`key_vault_artifact_registry_external_readers` etc. in `variables.tf` —
   Chameleon adds your service accounts to these lists and applies).
   Until that grant lands, the placeholder images in the tfvars template
   let the first apply succeed with no real container running yet.

## Install

**Fork this repo first if you plan to customize any of this Terraform for
your own product** (add resources, change configs, whatever fits what
you're building) — use the "Fork" button at the top of
[this repo on GitHub](https://github.com/BrechtVanBuggenhout/chameleon-installer),
then clone *your* fork below instead of Chameleon's repo directly. A fork
is your own separate repository: you can commit and push your changes to
it freely, and nothing you do there ever touches Chameleon's copy (GitHub
enforces that at the permission level — you don't have write access to
Chameleon's repo, full stop). Keep Chameleon's repo as an `upstream`
remote if you want to pull future updates without losing your changes:

```bash
git remote add upstream https://github.com/BrechtVanBuggenhout/chameleon-installer.git
git fetch upstream && git merge upstream/main
```

If you're just evaluating Chameleon as-is with no plans to customize it,
a plain clone is fine — `bootstrap.sh` will print a reminder about this
either way.

```bash
cp terraform.tfvars.byoc.example terraform.tfvars
# edit terraform.tfvars — at minimum, set bigquery_rls_admin_email

./scripts/bootstrap.sh <instance_name> <environment> <gcp_project_id> [region]
# example:
./scripts/bootstrap.sh acmebank prod acme-chameleon-prod us-central1
```

`instance_name` is your chosen identifier (lowercase, alphanumeric and
hyphens, 3–20 characters) — it names every resource. `environment` is a
**behavior tier**, not a naming choice: `prod` gets deletion protection and
always-warm scaling; `dev` scales to zero and has no deletion protection.
Most customers want `prod` even on their very first deploy — `dev` tier is
for genuinely disposable testing (see "Local/dev testing" below).

The script creates the Terraform state bucket, enables required GCP APIs,
then runs `terraform init` + `terraform apply`. On success it prints your
console URL and a generated password.

## Optional: build your own images instead of Chameleon's

By default, `key_vault_container_image`, `pii_ingestor_worker_container_image`,
and `console_image` point at Chameleon's own pre-built images (prerequisite
4 above grants your service accounts read access to pull them). That's the
simplest path and what most customers want.

If you'd rather not depend on Chameleon's container registry staying up
indefinitely, all three services' source is public and buildable yourself:

```bash
./scripts/build-own-images.sh <gcp_project_id> [region]
```

This builds all three images (from
[chameleon-vault](https://github.com/BrechtVanBuggenhout/chameleon-vault),
[chameleon-pii-ingestor](https://github.com/BrechtVanBuggenhout/chameleon-pii-ingestor),
and [chameleon-console](https://github.com/BrechtVanBuggenhout/chameleon-console))
straight from their GitHub URLs — no local clone needed — and pushes them
to an Artifact Registry repo in your own project, creating it if it
doesn't exist yet. Set the three `*_container_image`/`console_image`
values it prints to the resulting URIs in your `terraform.tfvars` before
running `bootstrap.sh`. Requires `docker` in addition to the prerequisites
above.

## If you're on Snowflake instead of BigQuery

Chameleon's core control plane (encryption keys, the deletion state machine,
Firestore, Pub/Sub) always runs in this GCP project regardless of which
warehouse holds your data — only the ingestion write path and the
`chameleon_pii` dbt package's registry/lineage tables become Snowflake
instead of BigQuery. This is BYOC: your Snowflake account already exists;
Chameleon only needs credentials to it, nothing is provisioned on the
Snowflake side by this repo.

Before running `bootstrap.sh`, on your own Snowflake account:

1. Create (or choose) a warehouse, a database, and a schema for Chameleon
   to land data into.
2. Create a dedicated user + role granted `USAGE` on the warehouse/database/
   schema and `INSERT`/`SELECT` on the landing table (Chameleon creates the
   table itself on first write; grant at the schema level so it applies to
   new tables too).
3. In `terraform.tfvars`, set:
   ```hcl
   pii_warehouse_type               = "snowflake"
   pii_ingestor_snowflake_account   = "XY12345-AB67890"
   pii_ingestor_snowflake_user      = "chameleon_ingestor"
   pii_ingestor_snowflake_role      = "chameleon_ingestor_role"
   pii_ingestor_snowflake_warehouse = "your_warehouse"
   pii_ingestor_snowflake_database  = "your_database"
   pii_ingestor_snowflake_schema    = "your_schema"
   ```
   The password is never set via tfvars — after the first apply, set it
   directly in Secret Manager:
   ```bash
   echo -n "your-password" | gcloud secrets versions add \
     pii-ingestor-snowflake-password-<instance_name> --data-file=-
   ```
   Then redeploy the worker (or wait for its next revision) to pick it up.
4. If you also want the `chameleon_pii` dbt package's registry/lineage read
   in Key Vault to come from the same Snowflake account, set the parallel
   `pii_registry_snowflake_*` vars (see the commented block in
   `terraform.tfvars.byoc.example`) and its own password secret,
   `pii-registry-snowflake-password-<instance_name>`.

Warehouse-discovery scanning (undeclared-PII crawling) and the ghost-data/
lineage dashboard are BigQuery-only today — not yet built for Snowflake.
Everything else (ingestion, encryption, crypto-shred deletion, certificates)
works the same regardless of warehouse.

## Verify: the end-to-end loop

This is the same loop the whole product rests on — do this before
considering the install done.

1. **Open the console** at the printed URL, log in with the printed
   password.
2. **Ingest a test record.** The real path is a CSV dropped in the landing
   zone bucket (`gcloud storage buckets list --project=<project> --filter="name:landing"`
   to find it), picked up by the worker within ~60s:
   ```bash
   printf 'user_id,email\ntest-user-1,test@example.com\n' | \
     gcloud storage cp - "gs://<landing-zone-bucket>/inbound/test-$(date +%s).csv"
   ```
3. **Trigger a deletion** for `test-user-1` from the console's Deletion
   page. Watch it move through the state machine (key destroyed → cascade
   → certificate issued) in well under a minute.
4. **Open the Proof page** for `test-user-1` and confirm a certificate
   renders — decode the JWT and check the claims (issuer, key fingerprint,
   lineage summary) make sense.

If all four steps work, the install is verified end to end: discovery,
encryption, key destruction, and provable erasure are all live.

## Local/dev testing

For testing against a throwaway `dev`-tier instance without setting up
authentication at all, set `key_vault_auth_bypass_enabled = true` in your
tfvars (or pass `-var key_vault_auth_bypass_enabled=true` to the bootstrap
script). Key Vault then runs with its API-key check disabled entirely —
useful for quick local iteration. This is **structurally impossible on a
`prod`-tier instance**: the variable's own validation rejects
`environment = "prod"` with bypass enabled before Terraform even computes a
plan, so this can't leak into a real deployment by mistake. Never hold
real customer data in a bypass-enabled instance.

## Troubleshooting

- **"instance_name must be 3-20 characters..."** — the validation error is
  literal; GCP service-account IDs cap at 30 characters, and the shorter
  fields in this module need the headroom.
- **Images still the `cloudrun/container/hello` placeholder after apply** —
  expected until Chameleon grants your project's service accounts registry
  access (see prerequisite 4) and you re-run with real `*_container_image` /
  `console_image` values.
- **First apply is slow** — API enablement can take a minute or two to
  propagate; `bootstrap.sh` enables them up front specifically to avoid
  this, but a retry of `terraform apply` (same command, no `bootstrap.sh`
  re-run needed) resolves any leftover propagation-timing errors.
- **Terraform state locked / backend reconfiguration needed** — standard
  Terraform mechanics, not specific to this module: `terraform force-unlock
  <lock-id>` for a stuck lock, or re-run `terraform init -reconfigure` if
  you need to point at a different state bucket.
- Anything else: contact Chameleon — see the README.
