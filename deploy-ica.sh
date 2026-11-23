#!/bin/bash
# ============================================================
# deploy-ica.sh - Intune App Catalog with Docker Compose, behind NOBS Inventory's shared Caddy proxy (HTTPS)
#
#   sudo ICA_HOST=apps.example.ch ./deploy-ica.sh     first install, or re-run after changes (safe to repeat)
#   sudo ./deploy-ica.sh --no-proxy                    without the shared proxy (another one is in front)
#
# Creates (never overwrites existing values):
#   .env                     non-secret settings (missing keys are added)
#   secrets/admin_password   the admin password (generated, shown once at the end)
#
# Then starts the app and waits until it is healthy. With NOBS Inventory's shared proxy on this server
# (NOBS_DIR, default /opt/nobs-inventory or ../nobs-inventory): writes the site file
# proxy/sites/intune-catalog.caddy there and restarts the proxy - HTTPS with the proxy's certificate.
#
# Environment overrides (optional):
#   ICA_HOST=apps.example.ch      name people type (required on first run; asked for otherwise)
#   NOBS_DIR=/opt/nobs-inventory  where NOBS Inventory (and its proxy/) is
#   ICA_IMAGE=ghcr.io/monsama/intune-app-catalog:2.38.13   a pinned image (default: the version in code)
#   BUILD_NETWORK=host            build with host networking (needed behind some proxies)
# ============================================================
set -Eeuo pipefail
trap 'echo "[ERROR] Failed at line $LINENO: $BASH_COMMAND" >&2' ERR
cd "$(dirname "$0")"
BASE_DIR="$(pwd)"
VERSION="$(grep -oE 'AppVersion = "[0-9.]+"' code/Private/AppState.ps1 | grep -oE '[0-9.]+')"
NO_PROXY_FLAG=false
for a in "$@"; do case "$a" in --no-proxy) NO_PROXY_FLAG=true ;; *) echo "[ERROR] Unknown option: $a" >&2; exit 1 ;; esac; done

info() { echo "[INFO]  $*"; }
warn() { echo "[WARN]  $*"; }
fail() { echo "[ERROR] $*" >&2; exit 1; }
gen_secret() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "$1"; }
set_env() { # key value: added when missing, never changed
    grep -q "^$1=" .env 2>/dev/null || echo "$1=$2" >> .env
}

echo "Step 1: Preflight"
if [ "$(id -u)" -ne 0 ] && ! id -nG | grep -qw docker; then fail "Run with sudo (or as a member of the docker group)."; fi
command -v docker >/dev/null || fail "Docker is not installed."
docker compose version >/dev/null 2>&1 || fail "The Docker Compose plugin is missing."
command -v openssl >/dev/null || fail "openssl is missing."
docker info >/dev/null 2>&1 || fail "The Docker daemon is not running."
info "OK - version $VERSION"

echo; echo "Step 2: Settings (.env)"
host="${ICA_HOST:-}"
if [ -z "$host" ] && [ -f .env ] && grep -q '^ICA_HOST=' .env; then host="$(grep '^ICA_HOST=' .env | tail -1 | cut -d= -f2-)"; fi
if [ -z "$host" ] && [ -t 0 ]; then read -r -p "Name people will type (e.g. apps.example.ch): " host; fi
[ -n "$host" ] || fail "Set ICA_HOST, e.g. sudo ICA_HOST=apps.example.ch ./deploy-ica.sh"
[[ "$host" =~ ^[A-Za-z0-9.-]+$ ]] || fail "ICA_HOST must be a host name (letters, digits, dots, dashes): $host"
touch .env; chmod 600 .env
set_env ICA_HOST "$host"
set_env ICA_IMAGE "${ICA_IMAGE:-ghcr.io/monsama/intune-app-catalog:$VERSION}"
set_env TZ "${TZ:-Europe/Zurich}"
info "Name: $(grep '^ICA_HOST=' .env | cut -d= -f2-)"

echo; echo "Step 3: Secrets"
mkdir -p secrets; chmod 700 secrets
NEW_PASSWORD=""
if [ ! -s secrets/admin_password ]; then
    NEW_PASSWORD="$(gen_secret 24)"
    printf '%s' "$NEW_PASSWORD" > secrets/admin_password
fi
# Read by the app's own user in the container (uid 10001); the folder around it stays root's.
chmod 444 secrets/admin_password
info "OK"

echo; echo "Step 4: Network and app"
docker network inspect nobs-proxy >/dev/null 2>&1 || { docker network create nobs-proxy >/dev/null; info "Created the network nobs-proxy."; }
IMG="$(grep '^ICA_IMAGE=' .env | cut -d= -f2-)"
if docker image inspect "$IMG" >/dev/null 2>&1; then info "Image $IMG is here."
elif ! docker compose pull app 2>/dev/null; then
    warn "The image could not be pulled - building it here."
    if [ -n "${BUILD_NETWORK:-}" ]; then docker build --network "$BUILD_NETWORK" -t "$(grep '^ICA_IMAGE=' .env | cut -d= -f2-)" .; else docker compose build app; fi
fi
docker compose up -d app
info "Waiting until the app is healthy..."
for _ in $(seq 1 60); do
    s="$(docker inspect -f '{{.State.Health.Status}}' intune-app-catalog 2>/dev/null || echo starting)"
    [ "$s" = "healthy" ] && break
    [ "$s" = "unhealthy" ] && { docker compose logs --tail 40 app; fail "The app is unhealthy - see the log above."; }
    sleep 3
done
[ "$s" = "healthy" ] || { docker compose logs --tail 40 app; fail "The app did not become healthy in 3 minutes."; }
info "Healthy."

echo; echo "Step 5: HTTPS (the shared proxy)"
if $NO_PROXY_FLAG; then
    info "Skipped (--no-proxy): forward https://$host to intune-app-catalog:8080 on the network nobs-proxy."
    info "Set ICA_TRUSTED_PROXY in .env to that proxy's container name or address - else every client counts as one for wrong passwords."
else
    nobs="${NOBS_DIR:-}"
    for d in "$nobs" /opt/nobs-inventory "$BASE_DIR/../nobs-inventory"; do [ -n "$d" ] && [ -d "$d/proxy/sites" ] && { nobs="$d"; break; }; done
    if [ -z "$nobs" ] || [ ! -d "$nobs/proxy/sites" ]; then
        warn "NOBS Inventory's proxy wasn't found (set NOBS_DIR). Add this site to your proxy by hand:"
        echo "    https://$host { import tls_and_headers; reverse_proxy intune-app-catalog:8080 }"
    else
        site="$nobs/proxy/sites/intune-catalog.caddy"
        # Kept when it is there: it may point at a certificate of its own (install-cert.sh).
        if [ ! -f "$site" ]; then
            printf 'https://%s {\n\timport tls_and_headers\n\treverse_proxy intune-app-catalog:8080\n}\n' "$host" > "$site"
            info "Wrote $site"
        else
            info "Kept $site (it is there already)."
        fi
        if docker ps --format '{{.Names}}' | grep -qx nobs-proxy; then docker restart nobs-proxy >/dev/null && info "Restarted nobs-proxy."
        else warn "nobs-proxy isn't running - start it with NOBS Inventory's deploy-nobs.sh or update.sh."; fi
    fi
fi

echo
echo "============================================================"
echo " Intune App Catalog $VERSION is running: https://$host"
if [ -n "$NEW_PASSWORD" ]; then
    echo " Admin password (shown once - it is in secrets/admin_password):"
    echo "     $NEW_PASSWORD"
fi
echo " Next: sign in, then Settings > Connection - import the app registration's"
echo " certificate (.pfx) or create one and add its .cer in Entra ID."
echo "============================================================"
