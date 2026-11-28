#!/bin/bash
set -euo pipefail
umask 077

exec > >(tee -a /var/log/deploy-incident.log) 2>&1

DEPLOY_DIR="/opt/incident-lifecycle-manager-deploy"

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

compose_for() {
  local manifest="$1"
  shift

  docker compose \
    --env-file "$DEPLOY_DIR/.env" \
    --env-file "$manifest" \
    "$@"
}

smoke_test() {
  local attempt

  for attempt in 1 2 3; do
    if python3 "$DEPLOY_DIR/scripts/smoke_test.py" \
      "https://webexp.me"; then
      log "Smoke tests passed."
      return 0
    fi

    log "Smoke test attempt $attempt failed." >&2

    if ((attempt < 3)); then
      sleep 5
    fi
  done

  return 1
}

if [[ $# -ne 1 ]]; then
  echo "Usage: deploy.sh /absolute/path/to/updates.env" >&2
  exit 2
fi

# Resolve the supplied path before changing directories.
updates_file=$(realpath -- "$1")

if [[ ! -f "$updates_file" || ! -r "$updates_file" ]]; then
  echo "Updates manifest is missing or unreadable." >&2
  exit 1
fi

cd "$DEPLOY_DIR"

exec 9>.deploy.lock
flock -n 9 || {
  log "A deployment is already running." >&2
  exit 1
}

[[ -f .env && -f release/current.env ]] || {
  log ".env and current.env must exist." >&2
  exit 1
}

# Shell environment variables override Compose env files.
# Remove inherited image variables so the manifests control selection.
unset IMAGE_TAG PREVIOUS_IMAGE_TAG
unset POSTGRES_IMAGE POSTGRES_BACKUP_IMAGE VAULT_IMAGE
unset PROMETHEUS_IMAGE BACKEND_IMAGE FRONTEND_IMAGE GRAFANA_IMAGE
unset WAF_IMAGE POSTGRES_EXPORTER_IMAGE NODE_EXPORTER_IMAGE MIGRATE_IMAGE

work_dir=$(mktemp -d "$DEPLOY_DIR/.deploy.XXXXXX")
trap 'rm -rf -- "$work_dir"' EXIT

# Snapshot inputs while holding the deployment lock.
cp -- release/current.env "$work_dir/current.env"
cp -- "$updates_file" "$work_dir/updates.env"

incoming="$work_dir/incoming.env"
baseline="$work_dir/current.env"

python3 scripts/merge_images.py \
  "$baseline" "$work_dir/updates.env" >"$incoming"

log "Validating candidate release."
compose_for "$incoming" config --quiet

# Check Python syntax before making container changes.
python3 -c \
  'import ast, pathlib; ast.parse(pathlib.Path("scripts/smoke_test.py").read_text())'

log "Pulling candidate images."
compose_for "$incoming" pull

if compose_for "$incoming" up \
  -d --no-build --wait --wait-timeout 300 &&
  smoke_test; then

  # Preserve rollback history when redeploying identical references.
  if ! cmp -s "$incoming" release/current.env; then
    cp -- "$baseline" "$work_dir/previous.env"
    mv -- "$work_dir/previous.env" release/previous.env
    mv -- "$incoming" release/current.env
  fi

  log "Deployment succeeded; successful image references recorded."
else
  log "Deployment failed. Restoring the last successful image list." >&2

  if compose_for "$baseline" up \
    -d --no-build --wait --wait-timeout 300 &&
    smoke_test; then
    log "Rollback passed health and smoke checks."
  else
    log "Rollback failed checks. Inspect service logs." >&2
  fi

  exit 1
fi

log "Image cleanup is disabled until manifest-based retention is installed."
log "Deployment script finished."
