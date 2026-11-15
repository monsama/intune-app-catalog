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
sed -i "s#^ICA_IMAGE=.*#ICA_IMAGE=$NEW#" .env
docker compose pull app || docker compose build app
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
fail "Update failed; $OLD is running again. See: docker compose logs app"
