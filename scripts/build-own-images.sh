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
# name:url pairs, space-separated (avoiding bash 4+ associative arrays for
# portability to macOS's default bash 3.2).
SERVICES="key-vault:https://github.com/BrechtVanBuggenhout/chameleon-vault.git pii-ingestor:https://github.com/BrechtVanBuggenhout/chameleon-pii-ingestor.git console:https://github.com/BrechtVanBuggenhout/chameleon-console.git"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

for entry in $SERVICES; do
  name="${entry%%:*}"
  url="${entry#*:}"
  image="${REGISTRY}/${name}:latest"
  clone_dir="${WORKDIR}/${name}"

  log "Cloning ${name} from ${url}"
  # A real local clone, not `docker build <git-url>` directly -- that form
  # builds straight from a remote git URL as the context, and in practice
  # Docker's fetch of that context isn't reliably busted by re-running this
  # script (even with --no-cache, which only covers the Dockerfile's own
  # instruction cache, not the upstream context fetch). A real customer hit
  # this: rebuilding to pick up a fix silently produced a byte-identical,
  # stale image. Cloning fresh into a real directory removes the ambiguity
  # entirely -- the build context is exactly whatever's on disk right now.
  git clone --depth 1 "$url" "$clone_dir"
  echo "  building from: $(git -C "$clone_dir" log -1 --oneline)"

  log "Building ${name}"
  # Cloud Run only runs linux/amd64. Without --platform, docker build
  # defaults to the host's own architecture -- on Apple Silicon (or any
  # ARM host) that silently produces an arm64 image that fails at
  # startup with "exec format error" once deployed, since there's
  # nothing in a plain `docker build` to catch an architecture mismatch
  # ahead of time. --no-cache guards against a stale Dockerfile-layer
  # rebuild on a machine that's run this script before.
  docker build --no-cache --platform=linux/amd64 -t "$image" "$clone_dir"

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
