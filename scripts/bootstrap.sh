#!/usr/bin/env bash
# Bootstraps a fresh Chameleon instance (BYOC or managed-dedicated) into a
# GCP project: creates the Terraform state bucket, enables required APIs,
# then runs terraform init/apply. See ../INSTALL.md for the full walkthrough.
#
# Usage:
#   ./scripts/bootstrap.sh <instance_name> <environment> <gcp_project_id> [region]
#
# Example:
#   ./scripts/bootstrap.sh acmebank prod acme-chameleon-prod us-central1
#
# Prerequisites (checked below, not created for you):
#   - gcloud and terraform installed
#   - gcloud authenticated (gcloud auth login) with owner/editor-equivalent
#     rights on the target project — this is a normal expectation for a
#     project you already own, not a special grant
#   - the GCP project exists with billing enabled
#   - a terraform.tfvars file alongside this script (copy
#     terraform.tfvars.byoc.example and fill in bigquery_rls_admin_email
#     at minimum)
set -euo pipefail

INSTANCE_NAME="${1:?Usage: bootstrap.sh <instance_name> <environment> <gcp_project_id> [region]}"
ENVIRONMENT="${2:?environment must be 'dev' or 'prod' (a behavior tier, not a naming choice — see variables.tf)}"
PROJECT_ID="${3:?gcp_project_id is required}"
REGION="${4:-us-central1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

STATE_BUCKET="chameleon-tfstate-${INSTANCE_NAME}"
BACKEND_HCL="backend-${INSTANCE_NAME}.hcl"
TFVARS_FILE="terraform.tfvars"

log() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------------------
log "Preflight checks"
command -v gcloud >/dev/null 2>&1 || fail "gcloud CLI not found. Install: https://cloud.google.com/sdk/docs/install"
command -v terraform >/dev/null 2>&1 || fail "terraform not found. Install: https://developer.hashicorp.com/terraform/install"

TF_VERSION="$(terraform version -json | python3 -c 'import json,sys; print(json.load(sys.stdin)["terraform_version"])' 2>/dev/null || echo "0.0.0")"
python3 - "$TF_VERSION" <<'PYEOF' || fail "Terraform >= 1.9 required (cross-variable validation); found ${TF_VERSION}"
import sys
have = tuple(int(x) for x in sys.argv[1].split(".")[:2])
sys.exit(0 if have >= (1, 9) else 1)
PYEOF

ACTIVE_ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -1)"
[ -n "$ACTIVE_ACCOUNT" ] || fail "No active gcloud account. Run: gcloud auth login && gcloud auth application-default login"
echo "  gcloud account: ${ACTIVE_ACCOUNT}"

gcloud projects describe "$PROJECT_ID" >/dev/null 2>&1 || fail "Project '${PROJECT_ID}' not found or not accessible to ${ACTIVE_ACCOUNT}."
BILLING_ENABLED="$(gcloud billing projects describe "$PROJECT_ID" --format='value(billingEnabled)' 2>/dev/null || echo "false")"
[ "$BILLING_ENABLED" = "True" ] || fail "Project '${PROJECT_ID}' does not have billing enabled."
echo "  project: ${PROJECT_ID} (billing enabled)"

[ -f "$TFVARS_FILE" ] || fail "No ${TFVARS_FILE} found. Copy terraform.tfvars.byoc.example to ${TFVARS_FILE} and fill in the required values (at minimum: bigquery_rls_admin_email) first."

# ---------------------------------------------------------------------------
log "Creating Terraform state bucket (if missing): gs://${STATE_BUCKET}"
if gcloud storage buckets describe "gs://${STATE_BUCKET}" --project="$PROJECT_ID" >/dev/null 2>&1; then
  echo "  already exists"
else
  gcloud storage buckets create "gs://${STATE_BUCKET}" \
    --project="$PROJECT_ID" \
    --location="$REGION" \
    --uniform-bucket-level-access
  gcloud storage buckets update "gs://${STATE_BUCKET}" --versioning
  echo "  created, versioning enabled"
fi

cat > "$BACKEND_HCL" <<EOF
bucket = "${STATE_BUCKET}"
prefix = "chameleon/terraform"
EOF
echo "  wrote ${BACKEND_HCL}"

# ---------------------------------------------------------------------------
log "Enabling required GCP APIs"
REQUIRED_APIS=(
  firestore.googleapis.com
  bigquery.googleapis.com
  storage.googleapis.com
  iam.googleapis.com
  cloudresourcemanager.googleapis.com
  cloudkms.googleapis.com
  secretmanager.googleapis.com
  logging.googleapis.com
  artifactregistry.googleapis.com
  run.googleapis.com
  pubsub.googleapis.com
  cloudscheduler.googleapis.com
)
# Enabling these up front avoids the first apply failing on API-propagation
# timing; Terraform also declares them, so this is a fast idempotent no-op
# on any later run.
gcloud services enable "${REQUIRED_APIS[@]}" --project="$PROJECT_ID"
echo "  enabled ${#REQUIRED_APIS[@]} APIs"

# ---------------------------------------------------------------------------
log "terraform init"
terraform init -backend-config="$BACKEND_HCL" -reconfigure -input=false

WORKSPACE_NAME="$INSTANCE_NAME"
terraform workspace select "$WORKSPACE_NAME" 2>/dev/null || terraform workspace new "$WORKSPACE_NAME"

log "terraform apply"
terraform apply -input=false -auto-approve \
  -var-file="$TFVARS_FILE" \
  -var="instance_name=${INSTANCE_NAME}" \
  -var="environment=${ENVIRONMENT}" \
  -var="gcp_project_id=${PROJECT_ID}" \
  -var="gcp_region=${REGION}"

# ---------------------------------------------------------------------------
log "Done"
CONSOLE_URL="$(terraform output -raw console_cloud_run_url 2>/dev/null || echo "(see 'terraform output console_cloud_run_url')")"
CONSOLE_PASSWORD="$(terraform output -raw console_password 2>/dev/null || echo "(see 'terraform output console_password')")"

cat <<EOF

  Console URL:      ${CONSOLE_URL}
  Console password:  ${CONSOLE_PASSWORD}

Next: open the console URL, log in with the password above, and run the
end-to-end test in INSTALL.md (ingest a test record, trigger a deletion,
confirm the certificate).
EOF
