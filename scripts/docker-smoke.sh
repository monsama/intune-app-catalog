#!/bin/bash
# docker-smoke.sh - starts an image of the server version and checks what can be checked without a tenant:
# health, sign-in (wrong password refused, a second sign-in takes the first session over, sign-out), the host and
# origin rules, and - with internet - winget's package index.
#   ./scripts/docker-smoke.sh [image]        (default: intune-app-catalog:smoke, built first when it isn't there)
set -Eeuo pipefail
cd "$(dirname "$0")/.."
IMG="${1:-intune-app-catalog:smoke}"
PORT="${SMOKE_PORT:-18099}"
NAME="ica-smoke-$$"
fail() { echo "FAIL: $*" >&2; docker logs "$NAME" 2>&1 | tail -30 >&2 || true; docker rm -f "$NAME" >/dev/null 2>&1 || true; exit 1; }
ok() { echo "ok   $*"; }
docker image inspect "$IMG" >/dev/null 2>&1 || docker build -t "$IMG" .
dir="$(mktemp -d)"; trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf "$dir"' EXIT
printf 'smoke-test-password-%s' "$$" > "$dir/admin_password"; chmod 444 "$dir/admin_password"
PW="$(cat "$dir/admin_password")"
docker run -d --name "$NAME" -p "127.0.0.1:$PORT:8080" --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges:true \
  -e ICA_HOST=apps.example.test -e ICA_ADMIN_PASSWORD_FILE=/run/secrets/admin_password \
  -v "$dir/admin_password:/run/secrets/admin_password:ro" -v "$NAME-data:/app/data" "$IMG" >/dev/null
for _ in $(seq 1 60); do [ "$(docker inspect -f '{{.State.Health.Status}}' "$NAME")" = healthy ] && break; sleep 2; done
[ "$(docker inspect -f '{{.State.Health.Status}}' "$NAME")" = healthy ] || fail "not healthy"
ok "healthy"
B="http://127.0.0.1:$PORT"
# From outside the container (as through the proxy): the public name. localhost is for the health check inside.
post() { curl -s --noproxy '*' -H 'Host: apps.example.test' -H 'Content-Type: application/json' -X POST -d "$2" "$B$1"; }
field() { python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$1',''))"; }
[ "$(post /api/hello '{}' | field server)" = "True" ] || fail "hello: not the server version"; ok "server mode"
[ "$(post /api/hello '{}' | python3 -c "import sys,json; s=json.load(sys.stdin)['signIn']; print(s['password'], s['entra'])")" = "True False" ] || fail "hello: the sign-in ways"; ok "sign-in: the password, not Microsoft (not set up)"
code="$(curl -s --noproxy '*' -o /dev/null -w '%{http_code} %{redirect_url}' -H 'Host: apps.example.test' "$B/auth/login")"; [ "$code" = "302 http://127.0.0.1:$PORT/login.html?why=entra-off" ] || fail "/auth/login ($code)"; ok "Sign in with Microsoft off: /auth/login says so"
post /api/login '{"password":"wrong one"}' | grep -q 'Wrong password' || fail "a wrong password was not refused"; ok "wrong password refused"
T1="$(post /api/login "{\"password\":\"$PW\"}" | field token)"; [ -n "$T1" ] || fail "sign-in"; ok "signed in"
[ "$(post /api/ping "{\"token\":\"$T1\"}" | field ok)" = "True" ] || fail "session not open"
T2="$(post /api/login "{\"password\":\"$PW\"}" | field token)"
[ "$(post /api/ping "{\"token\":\"$T1\"}" | field reason)" = "takenover" ] || fail "the first session was not taken over"; ok "a second sign-in takes the session over"
[ "$(post /api/ping "{\"token\":\"$T2\"}" | field ok)" = "True" ] || fail "the new session is not open"
code="$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' -H 'Host: evil.example' "$B/")"; [ "$code" = 403 ] || fail "another host name was answered ($code)"; ok "other host names refused"
code="$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' -H 'Host: apps.example.test' -H 'Origin: https://evil.example' -H 'Content-Type: application/json' -d "{\"token\":\"$T2\"}" "$B/api/ping")"; [ "$code" = 403 ] || fail "another origin was answered ($code)"; ok "other origins refused"
code="$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' "$B/login.html")"; [ "$code" = 403 ] || fail "localhost from outside the container was answered ($code)"; ok "localhost only from inside"
code="$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' -H 'Host: apps.example.test' "$B/login.html")"; [ "$code" = 200 ] || fail "the public name was refused ($code)"; ok "the public name answered"
if [ "${SMOKE_WINGET:-1}" = 1 ]; then
  r="$(post /api/winget-search "{\"token\":\"$T2\",\"q\":\"7zip.7zip\"}")"
  echo "$r" | grep -q '"7zip.7zip"' || fail "winget search from the index: $r"; ok "winget's index answers"
fi
big="$(head -c 40000 /dev/zero | tr '\0' 'a')"
r="$(post /api/settings "{\"token\":\"$T2\",\"x\":\"$big\"}")"; echo "$r" | grep -q 'bad token' || fail "a large body without the session header was read: $r"
r="$(curl -s --noproxy '*' -H 'Host: apps.example.test' -H 'Content-Type: application/json' -H "X-ICA-Session: $T2" -d "{\"token\":\"$T2\",\"x\":\"$big\"}" "$B/api/settings")"; echo "$r" | grep -q 'bad token' && fail "a large body with the session header was refused"; ok "large bodies only for the session"
# The PC helpers: the scripts for a Windows PC, and what the installed-app script copies made into a rule.
for h in installed-script winget-export-script; do
  [ "$(post /api/$h "{\"token\":\"$T2\"}" | field ok)" = "True" ] || fail "PC helper $h"
done
body="$(python3 -c 'import json,sys; print(json.dumps({"token":sys.argv[1],"text":json.dumps({"intuneAppCatalog":"installed-app","name":"Foo","key":"{12345678-1234-1234-1234-123456789012}","hive":"HKLM","windowsInstaller":True,"displayVersion":"1.2.3"})}))' "$T2")"
post /api/detection-from-paste "$body" | grep -q '"Msi"' || fail "detection from a pasted app"
post /api/detection-from-paste "{\"token\":\"$T2\",\"text\":\"nonsense\"}" | grep -q '"ok":false' || fail "nonsense paste was accepted"
ok "PC helper scripts and the pasted detection"
# The certificate with its private key (2.38.11): made here, exported as a .pfx that opens with its password.
th="$(post /api/cert-new "{\"token\":\"$T2\",\"subject\":\"ICA Smoke\"}" | field thumbprint)"; [ -n "$th" ] || fail "creating a certificate"
post /api/cert-export-pfx "{\"token\":\"$T2\",\"thumbprint\":\"$th\",\"password\":\"short\"}" | grep -q '"ok":false' || fail ".pfx export took a short password"
post /api/cert-export-pfx "{\"token\":\"$T2\",\"thumbprint\":\"$th\",\"password\":\"smoke-pfx-password\"}" | python3 -c "import sys,json,base64; d=json.load(sys.stdin); assert d.get('ok') and len(base64.b64decode(d['file'])) > 1000, d" || fail ".pfx export"
ok "certificate made and exported as a .pfx"
post /api/logout "{\"token\":\"$T2\"}" >/dev/null
[ "$(post /api/ping "{\"token\":\"$T2\"}" | field reason)" = "signedout" ] || fail "sign-out"; ok "signed out"
docker volume rm -f "$NAME-data" >/dev/null 2>&1 || true
echo "PASSED: the server version's smoke test."
