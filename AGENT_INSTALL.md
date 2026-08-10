# Installing Chameleon via an AI coding agent

You are an AI coding agent (Claude Code, Codex, or similar) with shell and
file access, installing Chameleon BYOC on behalf of a human operator. This
doc is written directly to you, not to them — it trades the narrative
explanations in `INSTALL.md` for an explicit sequence of commands, decision
points, and pass/fail checks you can execute and verify yourself. Read
`INSTALL.md` too if you want the "why" behind any step; this doc assumes it
and won't repeat it.

**Ground rule**: this is real cloud infrastructure billed to a real GCP
project. Follow your own tool's safety norms — show the human what a
command will do before running anything that creates billed resources,
grants IAM, or applies Terraform, and get an explicit go-ahead first. The
checkpoints below mark the specific places this matters most; they are not
the only places it applies.

## 0. Confirm you're in the right repo

```bash
ls INSTALL.md scripts/bootstrap.sh scripts/build-own-images.sh terraform.tfvars.byoc.example
```

If any of these are missing, stop — you're not in `chameleon-installer`
(or a fork of it) or `chameleon-infra-gcp`. Don't guess at an alternate
layout.

## 1. Gather required inputs — ASK THE HUMAN, do not assume

You cannot proceed without these. Ask for all of them up front rather than
one at a time:

1. **GCP project ID** for this deployment — must already exist, with
   billing enabled. You can create the project yourself if asked to
   (`gcloud projects create`), but never assume an existing project is the
   right target without confirmation.
2. **`instance_name`** — their chosen slug (lowercase, alphanumeric +
   hyphens, 3–20 characters). Suggest their company slug if they have no
   preference.
3. **`environment`** — `prod` or `dev`. Default to recommending `prod`
   (per `INSTALL.md`'s "Most customers want `prod` even on their very
   first deploy") unless they explicitly want disposable/throwaway testing.
4. **`bigquery_rls_admin_email`** — required in `terraform.tfvars`, no
   sensible default; must be theirs.
5. **Image source**: Chameleon's pre-built images (simpler, needs step 2a
   below) or self-built via `build-own-images.sh` (step 2b, no dependency
   on Chameleon's registry). If they don't have a preference, recommend
   pre-built for a first eval, self-built for anything longer-lived.
6. If BigQuery isn't their warehouse: confirm Snowflake, and get the
   account/user/role/warehouse/database/schema values INSTALL.md's
   "If you're on Snowflake instead of BigQuery" section asks for. The
   password is never a tfvars value — you'll set it via `gcloud secrets
   versions add` in step 5, after the first apply creates the secret.

Do not fill in placeholder values for any of these and proceed — a wrong
`gcp_project_id` bills the wrong account, and a wrong `bigquery_rls_admin_email`
fails silently until someone notices RLS isn't working.

## 2. Preflight

```bash
command -v gcloud terraform && terraform version
gcloud auth list --filter=status:ACTIVE --format='value(account)'
```

If `gcloud` isn't authenticated: run `gcloud auth login && gcloud auth
application-default login` and wait for the human to complete the browser
flow — this cannot be scripted around.

**CHECKPOINT**: confirm the active `gcloud` account is one the human
expects to be using for this project before continuing. A stale
`gcloud auth login` from an unrelated project is the single most common way
this goes wrong silently.

## 2a. Using Chameleon's pre-built images (skip if self-building)

```bash
cp terraform.tfvars.byoc.example terraform.tfvars
```

Edit `terraform.tfvars`: set `bigquery_rls_admin_email` at minimum, plus
any Snowflake vars from step 1.6. Leave `*_container_image`/`console_image`
at their placeholder defaults for now — bootstrap.sh's first apply
succeeds with those (`cloudrun/container/hello`), it just isn't real
Chameleon code yet.

You'll need the runtime service account emails to ask Chameleon for
registry read access — get them after the first apply:
```bash
terraform state list | grep google_service_account
```
Relay those to the human to pass along; you cannot grant this yourself,
it's on Chameleon's side (`*_artifact_registry_external_readers` in
`variables.tf`).

## 2b. Building your own images instead

```bash
cp terraform.tfvars.byoc.example terraform.tfvars
# edit terraform.tfvars: bigquery_rls_admin_email at minimum
./scripts/build-own-images.sh <gcp_project_id> [region]
```

Requires `docker` running locally. Takes several minutes (clones + builds
3 services, `--platform=linux/amd64` regardless of host arch). On success
it prints 3 `*_container_image`/`console_image` values — set those exact
values in `terraform.tfvars` before continuing.

Re-running this script later (to pick up a new fix) also redeploys any
Cloud Run service it finds already running for this project — no separate
manual redeploy step needed on top of it.

## 3. Bootstrap

**CHECKPOINT**: this is the step that actually creates billed GCP
resources and can take several minutes. Show the human the command you're
about to run (with their real values substituted) and get confirmation
before running it, even though `bootstrap.sh` itself doesn't prompt.

```bash
./scripts/bootstrap.sh <instance_name> <environment> <gcp_project_id> [region]
```

This creates the Terraform state bucket, enables required APIs, and runs
`terraform init` + `terraform apply -auto-approve`. It's `-auto-approve`
by design (it's meant to be non-interactive) — your confirmation to the
human replaces the interactive prompt Terraform would otherwise show.

It also writes `instance.auto.tfvars` (instance identity — safe to commit,
not gitignored) and `backend-<instance_name>.hcl` (state backend config).
Both are auto-loaded by Terraform from here on; a later `terraform plan` in
this directory needs no flags.

On success it prints a console URL and password. **Save both** — you'll
need the password for step 4, and if `CONSOLE_PASSWORD`-gated auth means
you can't reach the console from a headless environment, relay the URL and
password to the human instead of trying to complete the browser login
yourself.

If it fails on API-propagation timing (common on a brand-new project):
```bash
terraform apply -input=false -auto-approve -var-file=terraform.tfvars
```
(no `bootstrap.sh` re-run needed — `instance.auto.tfvars` already has
`instance_name`/`environment`/`gcp_project_id`/`gcp_region`).

## 4. Verify — do as much of this yourself as you can

Don't ask the human to "check it works" for anything you can check via
shell. Reserve their involvement for the one step that genuinely needs a
human (2FA/session-gated console login), plus any external state
(Snowflake grants) they alone can confirm.

```bash
# 1. All 3 Cloud Run services are up
gcloud run services list --project=<gcp_project_id> --format='table(metadata.name,status.url,status.conditions[0].status)'

# 2. Did the real code actually deploy? (not the cloudrun/container/hello placeholder)
#    Requires enable_source_staleness_check=true + a re-apply first (see below) --
#    until then sourceSha is null, which is expected, not a failure.
curl -s <key_vault_url>/version
curl -s <console_url>/api/version
# The PII ingestor worker requires run.invoker IAM (no public ingress) --
# curl it via an identity token if you have one, otherwise skip and rely on
# the other two plus the health check below.

# 3. Basic health
curl -s <key_vault_url>/health
```

To get `sourceSha` populated on `/version` (recommended so future redeploys
are verifiable the same way): set `enable_source_staleness_check = true` in
`terraform.tfvars` and `terraform apply` again. Requires
`enable_pii_ingestor_worker = true` (default) and, for a self-built image
path, that you already ran `build-own-images.sh` at least once.

**The one step you likely can't do yourself**: opening the console URL,
logging in with the printed password, and running the end-to-end loop
(`INSTALL.md`'s "Verify: the end-to-end loop" — ingest a test record,
trigger a deletion, confirm the certificate). If you have programmatic
`gcloud storage cp` access to drop the test CSV (step 2 of that loop) and
API access to trigger/check the deletion, you can do steps 2–4
non-interactively too; only the initial console login is a hard human
dependency if `CONSOLE_PASSWORD` is set.

Confirm idempotency before declaring done:
```bash
terraform plan -input=false -var-file=terraform.tfvars
```
Should show no changes. If it does, something didn't apply cleanly —
investigate before telling the human this is finished.

## 5. Known errors and their exact fixes

Don't treat these as investigation-worthy — they're documented, expected,
one-time gotchas with known resolutions:

- **`google_bigquery_connection_iam_member.terraform_deployer_connection_admin`
  fails on apply** (only if `enable_decrypted_views = true`): the identity
  applying Terraform can't grant IAM to itself. Run just that resource
  under an Owner-level identity:
  `terraform apply -target=google_bigquery_connection_iam_member.terraform_deployer_connection_admin`,
  then re-run the full apply.
- **"Error creating Database: ... already exists ... please use another
  database_id"**: the GCP project already has a default Firestore database
  from something unrelated. Set `firestore_database_id` in
  `terraform.tfvars` to any other name (see the commented example in
  `terraform.tfvars.byoc.example`) and re-apply.
- **Images still `cloudrun/container/hello` after apply**: expected until
  either (a) Chameleon grants registry access (pre-built path, step 2a) and
  you re-apply with real image values, or (b) you run
  `build-own-images.sh` (step 2b) and set its printed values.
- **"instance_name must be 3-20 characters..."**: literal — GCP
  service-account IDs cap at 30 characters, this validation isn't
  arbitrary.
- Anything else: `INSTALL.md`'s Troubleshooting section, then
  `TERRAFORM_SETUP.md` (private repo only — not synced publicly) for raw
  Terraform mechanics.

## 6. Handing back to the human

Report, concretely:
- Console URL + password (if you couldn't complete login yourself)
- Which image path was used (pre-built vs. self-built) and, if self-built,
  whether `enable_source_staleness_check` got turned on
- `terraform plan` output confirming no drift
- Which verification steps you completed yourself vs. which still need
  their action (most commonly: the console login + end-to-end loop, and
  telling Chameleon their service-account emails if on the pre-built path)
