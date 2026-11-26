#!/bin/bash
# backup-ica.sh - the app's data volume (catalog, packages, settings, the certificate store, logs) as
# backup/intune-app-catalog-<time>.tar.gz, with a .sha256 beside it.
# Kept: the newest ICA_BACKUP_KEEP (default 5), and none older than 14 days.
# Left out: what the app builds again by itself - the .intunewin packages (Package / the shared init.intunewin),
# and tmp/ (scratch files and sockets).
# The archive holds the connection certificate's private key: keep it private, copy it off the server.
# Restore: docker compose stop app; docker run --rm -v intune-app-catalog-data:/data -v "$PWD/backup":/b alpine \
#            sh -c 'rm -rf /data/* && tar -xzf /b/<file> -C /data'; docker compose start app
set -Eeuo pipefail
cd "$(dirname "$0")/.."
KEEP="${ICA_BACKUP_KEEP:-5}"
[[ "$KEEP" =~ ^[1-9][0-9]*$ ]] || { echo "[ERROR] ICA_BACKUP_KEEP must be a number of 1 or more." >&2; exit 1; }
mkdir -p backup; chmod 700 backup
name="intune-app-catalog-$(date +%Y%m%d-%H%M%S).tar.gz"

# Older than 14 days: gone first. The newest KEEP stay - old ones beyond that go after the new one is written
# (2.38.61: they went before, so with ICA_BACKUP_KEEP=1 a failed backup left none), or earlier only to make room.
find backup -name 'intune-app-catalog-*.tar.gz*' -mtime +14 -delete
prune() { ls -1t backup/intune-app-catalog-*.tar.gz 2>/dev/null | tail -n +"$1" | while read -r old; do rm -f -- "$old" "$old.sha256"; done; }

# Enough room? What goes in (without the rebuildable packages and tmp/), against what the disk has free.
need_kb="$(docker run --rm -v intune-app-catalog-data:/data:ro alpine:3.20 sh -c \
    "all=\$(du -sk /data | cut -f1); iw=\$(find /data -path /data/tmp -prune -o -type f -name '*.intunewin' -exec du -k {} + 2>/dev/null | awk '{s+=\$1} END {print s+0}'); tmp=\$(du -sk /data/tmp 2>/dev/null | cut -f1); echo \$(( all - iw - \${tmp:-0} ))")"
free_kb="$(df -Pk backup | awk 'NR==2 {print $4}')"
# Not enough: the ones beyond the newest KEEP-1 make room now (the newest stays whatever happens), then asked again.
if [ "${need_kb:-0}" -gt "${free_kb:-0}" ]; then prune "$(( KEEP > 1 ? KEEP : 2 ))"; free_kb="$(df -Pk backup | awk 'NR==2 {print $4}')"; fi
if [ "${need_kb:-0}" -gt "${free_kb:-0}" ]; then
    echo "[ERROR] Not enough free space for the backup: about $(( need_kb / 1024 )) MB needed, $(( free_kb / 1024 )) MB free on $(df -P backup | awk 'NR==2 {print $6}')." >&2
    echo "        Free some space (docker image prune -a; older files in backup/) or set ICA_BACKUP_KEEP lower, then try again." >&2
    exit 1
fi

# A half-written archive (the disk filled up after all, Ctrl+C) is removed, not left looking like a backup.
trap 'rm -f -- "backup/$name" "backup/$name.sha256"' ERR INT
# tmp/ holds the running app's scratch files and sockets (tar can't store a socket and says so) - not data.
# The folder itself is excluded, so tar doesn't go into it at all (2.38.36: only its contents were, and busybox tar
# still reported the sockets in it as "socket ignored" - harmless, but it looked like an error).
docker run --rm -v intune-app-catalog-data:/data:ro -v "$PWD/backup":/b alpine:3.20 tar -czf "/b/$name" \
    --exclude './tmp' --exclude 'tmp' --exclude './tmp/*' --exclude 'tmp/*' --exclude '*.intunewin' -C /data .
( cd backup && sha256sum "$name" > "$name.sha256" )
trap - ERR INT
# Written and checked: now the old ones beyond the newest KEEP go.
prune "$(( KEEP + 1 ))"
echo "[INFO]  backup/$name ($(du -h "backup/$name" | cut -f1); the newest $KEEP are kept)"
