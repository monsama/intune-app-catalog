#!/bin/bash
# backup-ica.sh - the app's data volume (catalog, packages, settings, the certificate store, logs) as
# backup/intune-app-catalog-<time>.tar.gz, with a .sha256 beside it; backups older than 14 days are removed.
# The archive holds the connection certificate's private key: keep it private, copy it off the server.
# Restore: docker compose stop app; docker run --rm -v intune-app-catalog-data:/data -v "$PWD/backup":/b alpine \
#            sh -c 'rm -rf /data/* && tar -xzf /b/<file> -C /data'; docker compose start app
set -Eeuo pipefail
cd "$(dirname "$0")/.."
mkdir -p backup; chmod 700 backup
name="intune-app-catalog-$(date +%Y%m%d-%H%M%S).tar.gz"
docker run --rm -v intune-app-catalog-data:/data:ro -v "$PWD/backup":/b alpine:3.20 tar -czf "/b/$name" -C /data .
( cd backup && sha256sum "$name" > "$name.sha256" )
find backup -name 'intune-app-catalog-*.tar.gz*' -mtime +14 -delete
echo "[INFO]  backup/$name"
