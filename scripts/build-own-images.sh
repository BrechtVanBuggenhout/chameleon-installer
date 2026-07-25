#!/usr/bin/env bash
# Builds all three Chameleon services (Key Vault, PII Ingestor Worker,
# Console) directly from their public source repos and pushes them to
# YOUR OWN Artifact Registry -- so your deployment never depends on
# Chameleon's own container registry staying up. This is entirely
# optional: skip it and bootstrap.sh pulls Chameleon's pre-built images
# instead, which is simpler and the default for most customers.
#
# Usage:
#   ./scripts/build-own-images.sh <gcp_project_id> [region]
#
# Requires docker and gcloud, authenticated with access to gcp_project_id.
# After this succeeds, set the three printed *_container_image /
# console_image values in your terraform.tfvars before running
# bootstrap.sh.
set -euo pipefail

PROJECT_ID="${1:?Usage: build-own-images.sh <gcp_project_id> [region]}"
REGION="${2:-us-central1}"
REPO_NAME="chameleon"
REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}"

log() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------------------
log "Preflight checks"
command -v docker >/dev/null 2>&1 || fail "docker not found. Install: https://docs.docker.com/get-docker/"
command -v gcloud >/dev/null 2>&1 || fail "gcloud CLI not found. Install: https://cloud.google.com/sdk/docs/install"
gcloud projects describe "$PROJECT_ID" >/dev/null 2>&1 || fail "Project '${PROJECT_ID}' not found or not accessible."

# ---------------------------------------------------------------------------
log "Creating Artifact Registry repo (if missing): ${REPO_NAME} in ${REGION}"
if gcloud artifacts repositories describe "$REPO_NAME" --project="$PROJECT_ID" --location="$REGION" >/dev/null 2>&1; then
  echo "  already exists"
else
  gcloud artifacts repositories create "$REPO_NAME" \
    --project="$PROJECT_ID" \
    --location="$REGION" \
    --repository-format=docker
  echo "  created"
fi

log "Configuring Docker auth"
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet

# ---------------------------------------------------------------------------
# Docker can build directly from a public git repo URL as the build
# context -- no local clone needed. name:url pairs, space-separated
# (avoiding bash 4+ associative arrays for portability to macOS's
# default bash 3.2).
SERVICES="key-vault:https://github.com/BrechtVanBuggenhout/chameleon-vault.git pii-ingestor:https://github.com/BrechtVanBuggenhout/chameleon-pii-ingestor.git console:https://github.com/BrechtVanBuggenhout/chameleon-console.git"

for entry in $SERVICES; do
  name="${entry%%:*}"
  url="${entry#*:}"
  image="${REGISTRY}/${name}:latest"

  log "Building ${name} from ${url}"
  docker build -t "$image" "$url"

  log "Pushing ${name}"
  docker push "$image"
  echo "  ${name} -> ${image}"
done

# ---------------------------------------------------------------------------
log "Done"
cat <<EOF

Set these in your terraform.tfvars before running bootstrap.sh:

  key_vault_container_image           = "${REGISTRY}/key-vault:latest"
  pii_ingestor_worker_container_image = "${REGISTRY}/pii-ingestor:latest"
  console_image                       = "${REGISTRY}/console:latest"

EOF
