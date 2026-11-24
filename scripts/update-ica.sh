#!/bin/bash
# update-ica.sh - Intune App Catalog to another release (default: the version in the code after git pull).
#   sudo ./scripts/update-ica.sh            git pull, then the image of that version
#   sudo ./scripts/update-ica.sh 2.28.1     that version's image
# Backs the data up first (scripts/backup-ica.sh); goes back to the image that was running when the new one isn't healthy.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
info() { echo "[INFO]  $*"; }
fail() { echo "[ERROR] $*" >&2; exit 1; }
[ -f .env ] || fail "No .env here - run deploy-ica.sh first."
if [ -z "${1:-}" ]; then git pull --ff-only; fi
VERSION="${1:-$(grep -oE 'AppVersion = "[0-9.]+"' code/Private/AppState.ps1 | grep -oE '[0-9.]+')}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Not a version: $VERSION"
OLD="$(grep '^ICA_IMAGE=' .env | cut -d= -f2-)"
NEW="ghcr.io/monsama/intune-app-catalog:$VERSION"
./scripts/backup-ica.sh
BACKUP="$(ls -1t backup/intune-app-catalog-*.tar.gz 2>/dev/null | head -1)"
# The release's image only: a failed pull stops here (a local build of this checkout isn't that release).
docker pull "$NEW" || fail "$NEW could not be pulled - nothing was changed."
sed -i "s#^ICA_IMAGE=.*#ICA_IMAGE=$NEW#" .env
docker compose up -d app
for _ in $(seq 1 60); do
    s="$(docker inspect -f '{{.State.Health.Status}}' intune-app-catalog 2>/dev/null || echo starting)"
    [ "$s" = "healthy" ] && { info "Running $NEW."; exit 0; }
    [ "$s" = "unhealthy" ] && break
    sleep 3
done
echo "[WARN]  $NEW isn't healthy - going back to $OLD." >&2
sed -i "s#^ICA_IMAGE=.*#ICA_IMAGE=$OLD#" .env
docker compose up -d app
# The data may already have been changed by the new version - the backup taken first is the way back.
echo "[WARN]  The data may have been changed by $NEW. To restore the backup taken before the update:" >&2
echo "        docker compose stop app; docker run --rm -v intune-app-catalog-data:/data -v \"\$PWD/backup\":/b alpine:3.20 sh -c 'rm -rf /data/* && tar -xzf /b/$(basename "${BACKUP:-<file>}") -C /data'; docker compose start app" >&2
fail "Update failed; $OLD is running again. See: docker compose logs app"
