#!/bin/bash
set -euo pipefail
umask 077

exec > >(tee -a /var/log/deploy-incident.log) 2>&1

DEPLOY_DIR="/opt/incident-lifecycle-manager-deploy"
CLEANUP_DRY_RUN=true
KEEP_DAYS=15

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

cleanup_images() {
  local current="$1"
  local previous="$2"
  local cutoff images image tag created created_epoch containers

  if [[ ! "$current" =~ ^[0-9a-f]{40}$ ||
    ! "$previous" =~ ^[0-9a-f]{40}$ ]]; then
    log "Skipping cleanup: current or previous SHA is missing/invalid."
    return 0
  fi

  cutoff=$(date -u -d "$KEEP_DAYS days ago" +%s) || return 1

  images=$(docker image ls \
    --filter 'reference=sofianvagabond/incident-*:*' \
    --format '{{.Repository}}:{{.Tag}}') || return 1

  while IFS= read -r image; do
    [[ -n "$image" ]] || continue
    tag="${image##*:}"

    # Always retain the current and previous successful releases.
    if [[ "$tag" == "$current" || "$tag" == "$previous" ]]; then
      log "KEEP protected: $image"
      continue
    fi

    # Leave named tags such as latest, v4, and migrations-v1 alone.
    [[ "$tag" =~ ^[0-9a-f]{40}$ ]] || continue

    created=$(docker image inspect \
      --format '{{.Created}}' "$image") || continue

    created_epoch=$(date -u -d "$created" +%s) || continue

    # Age is measured from image creation, not download time.
    if ((created_epoch >= cutoff)); then
      log "KEEP recent: $image"
      continue
    fi

    # Protect images referenced by running or stopped containers.
    # The ancestor filter also conservatively protects parent images.
    containers=$(docker ps -aq \
      --filter "ancestor=$image") || continue

    if [[ -n "$containers" ]]; then
      log "KEEP referenced by container: $image"
      continue
    fi

    if [[ "$CLEANUP_DRY_RUN" == "true" ]]; then
      log "WOULD DELETE: $image"
    else
      log "DELETE: $image"

      # Remove the tag without forcing removal.
      if ! docker image rm "$image"; then
        log "Could not remove: $image" >&2
      fi
    fi
  done <<<"$images"

  return 0
}

smoke_test() {
  # Test HTTPS through the local WAF using the real hostname.
  # Retry briefly to allow the application to settle.
  local attempt

  for attempt in 1 2 3; do
    if curl -fsS --connect-timeout 5 --max-time 10 \
      --resolve webexp.me:443:127.0.0.1 \
      https://webexp.me/api/v1/health >/dev/null; then
      log "API smoke test passed."
      return 0
    fi

    log "API smoke test attempt $attempt failed." >&2

    if ((attempt < 3)); then
      sleep 5
    fi
  done

  return 1
}

# Validate the requested release.
if [[ $# -ne 1 || ! ${1:-} =~ ^[0-9a-f]{40}$ ]]; then
  echo "Usage: deploy-incident <40-character release SHA>" >&2
  exit 2
fi

case "$CLEANUP_DRY_RUN" in
true | false) ;;
*)
  echo "CLEANUP_DRY_RUN must be true or false." >&2
  exit 1
  ;;
esac

release_sha="$1"
cd "$DEPLOY_DIR"

# Prevent inherited variables overriding the release stored in .env.
unset IMAGE_TAG PREVIOUS_IMAGE_TAG

# Keep the lock for both deployment and cleanup.
exec 9>.deploy.lock
flock -n 9 || {
  log "A deployment is already running." >&2
  exit 1
}

if [[ ! -f .env ]]; then
  log ".env is missing." >&2
  exit 1
fi

if [[ $(grep -c '^IMAGE_TAG=' .env) != 1 ]]; then
  log "Expected exactly one IMAGE_TAG entry in .env." >&2
  exit 1
fi

current_sha=$(sed -n 's/^IMAGE_TAG=//p' .env)
previous_sha=$(sed -n 's/^PREVIOUS_IMAGE_TAG=//p' .env)

if [[ ! "$current_sha" =~ ^[0-9a-f]{40}$ ]]; then
  log "IMAGE_TAG must be a plain 40-character SHA." >&2
  exit 1
fi

# An absent previous SHA is allowed when first adopting this script.
if [[ -n "$previous_sha" &&
  ! "$previous_sha" =~ ^[0-9a-f]{40}$ ]]; then
  log "PREVIOUS_IMAGE_TAG must be one plain 40-character SHA." >&2
  exit 1
fi

next_env=$(mktemp .env.deploy.XXXXXX)
trap 'rm -f -- "$next_env"' EXIT

if [[ "$release_sha" == "$current_sha" ]]; then
  # Preserve rollback history when redeploying the same release.
  cp -- .env "$next_env"
else
  previous_sha="$current_sha"

  sed \
    -e "s/^IMAGE_TAG=.*/IMAGE_TAG=$release_sha/" \
    -e '/^PREVIOUS_IMAGE_TAG=/d' \
    .env >"$next_env"

  printf '\nPREVIOUS_IMAGE_TAG=%s\n' "$previous_sha" >>"$next_env"
fi

log "Deploying $release_sha; existing release is $current_sha."

# Fail before changing containers if validation or pulling fails.
IMAGE_TAG="$release_sha" docker compose config --quiet
IMAGE_TAG="$release_sha" docker compose pull

if IMAGE_TAG="$release_sha" docker compose up \
  -d --no-build --wait --wait-timeout 300 &&
  smoke_test &&
  mv -- "$next_env" .env; then
  log "Deployed $release_sha."
else
  log "Deployment failed. Restoring $current_sha." >&2

  if IMAGE_TAG="$current_sha" docker compose up \
    -d --no-build --wait --wait-timeout 300 &&
    smoke_test; then
    log "Rollback passed health and smoke checks."
  else
    log "Rollback failed checks. Inspect service logs." >&2
  fi

  exit 1
fi

# Cleanup runs only after the release is successfully recorded.
# A cleanup failure does not trigger a rollback.
if ! cleanup_images "$release_sha" "$previous_sha"; then
  log "Deployment succeeded, but cleanup failed." >&2
fi

log "Deployment script finished."
