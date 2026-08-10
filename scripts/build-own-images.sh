#!/usr/bin/env bash
# Builds all three Chameleon services (Key Vault, PII Ingestor Worker,
# Console) directly from their public source repos and pushes them to
# YOUR OWN Artifact Registry -- so your deployment never depends on
# Chameleon's own container registry staying up. This is entirely
# optional: skip it and bootstrap.sh pulls Chameleon's pre-built images
# instead, which is simpler and the default for most customers.
#
# On a re-run against a project that already has these services deployed
# (i.e. you're rebuilding to pick up a fix, not installing for the first
# time), this also redeploys each one with the image it just pushed --
# `terraform apply` alone never does this (Cloud Run's `image` field is
# deliberately excluded from Terraform's management; see key_vault.tf /
# console.tf / pii_ingestor_worker.tf), so previously this was a manual
# `gcloud run deploy` per service that was easy to forget. First-time
# installs (no matching service exists yet) are unaffected -- see the
# "Set these in your terraform.tfvars" step below, unchanged.
#
# Usage:
#   ./scripts/build-own-images.sh [gcp_project_id] [region]
#
# gcp_project_id defaults to `gcloud config get-value project` if omitted.
# region defaults to us-central1.
#
# Requires docker and gcloud, authenticated with access to gcp_project_id.
# After this succeeds, set the three printed *_container_image /
# console_image values in your terraform.tfvars before running
# bootstrap.sh.
set -euo pipefail

log() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$1" >&2; exit 1; }

# Falls back to whatever `gcloud config` already has active rather than
# always requiring the arg -- but only ever a fallback: an explicit arg
# still wins, and an empty gcloud default still fails fast with the same
# usage message as before, rather than silently building against whatever
# project happened to be active.
if [ -n "${1:-}" ]; then
  PROJECT_ID="$1"
else
  PROJECT_ID="$(gcloud config get-value project 2>/dev/null || true)"
  [ -n "$PROJECT_ID" ] || fail "Usage: build-own-images.sh <gcp_project_id> [region] (no project ID given, and no default project set in gcloud config)"
fi
REGION="${2:-us-central1}"
REPO_NAME="chameleon"
REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}"

# Cloud Run service-name prefix each component is deployed under -- matches
# key_vault.tf/console.tf/pii_ingestor_worker.tf's naming exactly
# ("${var.app_name}-<component>-${local.instance_name}", app_name defaulting
# to "chameleon"). No bash 4 associative arrays (see SERVICES below).
service_name_prefix() {
  case "$1" in
    key-vault) echo "chameleon-key-vault-" ;;
    pii-ingestor) echo "chameleon-pii-ingestor-worker-" ;;
    console) echo "chameleon-console-" ;;
  esac
}

# Finds the single Cloud Run service (if any) matching a component's name
# prefix in this project/region and redeploys it with the image just
# pushed. Doesn't know (or need to know) instance_name -- BYOC's model is
# one instance per project, so a single match is the expected case. Zero
# matches means nothing's been deployed here yet (first-time install,
# bootstrap.sh hasn't run); more than one is genuinely ambiguous (multiple
# instances sharing a project) and left for a manual, deliberate redeploy
# rather than guessing which one you meant.
redeploy_matching_service() {
  component="$1"
  image="$2"
  prefix="$(service_name_prefix "$component")"

  matches="$(gcloud run services list --project="$PROJECT_ID" --region="$REGION" \
    --format='value(metadata.name)' --filter="metadata.name~^${prefix}" 2>/dev/null || true)"
  match_count="$(printf '%s\n' "$matches" | grep -c . || true)"

  if [ "$match_count" -eq 0 ]; then
    echo "  no existing ${prefix}* Cloud Run service in ${PROJECT_ID}/${REGION} -- nothing to redeploy yet (first install? set the *_container_image values below in terraform.tfvars, then run bootstrap.sh)"
  elif [ "$match_count" -gt 1 ]; then
    echo "  multiple ${prefix}* Cloud Run services found -- not auto-redeploying, ambiguous which instance this is for:"
    printf '    %s\n' $matches
    echo "  redeploy the right one yourself: gcloud run deploy <name> --image=${image} --project=${PROJECT_ID} --region=${REGION}"
  else
    log "Redeploying ${matches} with the image just pushed"
    gcloud run deploy "$matches" --image="$image" --project="$PROJECT_ID" --region="$REGION" --quiet
  fi
}

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

# Accumulated as plain "name:sha" pairs (same portability constraint as
# SERVICES above) and turned into the JSON blob written to Secret Manager
# once every image has built successfully -- see the "source staleness"
# block below.
BUILT_SHAS=""

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
  sha="$(git -C "$clone_dir" rev-parse HEAD)"
  echo "  building from: $(git -C "$clone_dir" log -1 --oneline)"
  BUILT_SHAS="${BUILT_SHAS} ${name}:${sha}"

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

  redeploy_matching_service "$name" "$image"
done

# ---------------------------------------------------------------------------
log "Recording source commits for the source-staleness check"
# Lets a weekly Cloud Scheduler job (opt-in: enable_source_staleness_check in
# terraform.tfvars) compare these against the public repos' current HEAD and
# log a warning if this deployment has drifted -- see pii_ingestor_worker.tf.
# Never sent anywhere outside this project; purely so re-running this same
# script later can tell you whether it needed to. Building the JSON by hand
# (not `jq`, which isn't a stated dependency of this script) since the value
# shape is trivial and fixed.
SHAS_JSON="{"
first=1
for entry in $BUILT_SHAS; do
  svc_name="${entry%%:*}"
  svc_sha="${entry#*:}"
  if [ "$first" = 1 ]; then
    first=0
  else
    SHAS_JSON="${SHAS_JSON},"
  fi
  SHAS_JSON="${SHAS_JSON}\"${svc_name}\":\"${svc_sha}\""
done
SHAS_JSON="${SHAS_JSON},\"builtAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"

if gcloud secrets describe chameleon-source-shas --project="$PROJECT_ID" >/dev/null 2>&1; then
  echo "  chameleon-source-shas already exists, adding a new version"
else
  gcloud secrets create chameleon-source-shas \
    --project="$PROJECT_ID" \
    --replication-policy=automatic
  echo "  created chameleon-source-shas"
fi
printf '%s' "$SHAS_JSON" | gcloud secrets versions add chameleon-source-shas --project="$PROJECT_ID" --data-file=-

# ---------------------------------------------------------------------------
log "Done"
cat <<EOF

Any existing Cloud Run service for these 3 components in ${PROJECT_ID}/${REGION}
was just redeployed with the image built above (see "Redeploying ..." lines
above, or "nothing to redeploy yet" if this is a first install).

First install? Set these in your terraform.tfvars before running bootstrap.sh:

  key_vault_container_image           = "${REGISTRY}/key-vault:latest"
  pii_ingestor_worker_container_image = "${REGISTRY}/pii-ingestor:latest"
  console_image                       = "${REGISTRY}/console:latest"

Verify a redeploy actually landed: curl each service's own /version (Key
Vault and the PII ingestor worker directly; console's proxies Key Vault's)
and check sourceSha against the SHAs this run just built -- see the
"building from" lines above. Populating sourceSha at all requires
enable_source_staleness_check = true in terraform.tfvars (see below).

Want a weekly reminder when these fall behind the public repos? Set
enable_source_staleness_check = true in your terraform.tfvars and re-apply
(after this first run -- it needs the chameleon-source-shas secret this
script just wrote). It only logs to this project's own Cloud Logging, never
to Chameleon -- see INSTALL.md for how to wire an alert to it.

EOF
