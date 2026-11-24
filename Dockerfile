# Intune App Catalog - the server version: the same app, in a Linux container behind a reverse proxy.
# Build: docker build -t intune-app-catalog .   Run: see docker-compose.yml and docs/docker.md.
# syntax=docker/dockerfile:1
FROM mcr.microsoft.com/powershell:7.5-ubuntu-24.04

# sqlite3 reads winget's package index (there's no winget on Linux), msitools reads an MSI's product code and
# version, curl is the health check. Security fixes Ubuntu has published since the base image was built.
# A stalled package mirror fails in seconds and is tried again, instead of holding the build for half an hour
# (CI took 29 minutes on this step once). APT_REFRESH: CI's weekly stamp, so a cached layer still gets the
# security fixes at least weekly; a plain docker build (the release) always runs it fresh.
ARG APT_REFRESH=
RUN printf 'Acquire::Retries "5";\nAcquire::http::Timeout "30";\nAcquire::https::Timeout "30";\n' > /etc/apt/apt.conf.d/80-retries \
 && apt-get update \
 && apt-get upgrade -y --no-install-recommends \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends sqlite3 msitools curl ca-certificates tzdata \
 && rm -rf /var/lib/apt/lists/*

# Microsoft Graph (sign-in and requests) for every user of the image - the app runs as a user without a home of its own.
# A build behind a proxy that inspects TLS: its CA as a build secret (docker build --secret id=buildca,src=ca.pem ...).
ARG GRAPH_AUTH_VERSION=2.41.2
RUN --mount=type=secret,id=buildca,required=false \
    if [ -f /run/secrets/buildca ]; then export SSL_CERT_FILE=/run/secrets/buildca; fi; \
    pwsh -NoLogo -NoProfile -Command 'Install-PSResource Microsoft.Graph.Authentication -Version $env:GRAPH_AUTH_VERSION -Repository PSGallery -Scope AllUsers -TrustRepository -ErrorAction Stop' \
 && rm -rf /root/.local/share/powershell /root/.cache

# ICA_SERVER: server mode (a sign-in, every address, no app window). HOME on the data volume: the .NET certificate
# store (the connection's certificate) lives there. TEMP/TMPDIR: working files (an installer staged and
# packaged) - on the data volume, not the small /tmp in memory, so a large installer fits.
ENV ICA_SERVER=1 ICA_PORT=8080 HOME=/app/data/home TEMP=/app/data/tmp TMPDIR=/app/data/tmp TZ=Europe/Zurich POWERSHELL_TELEMETRY_OPTOUT=1 POWERSHELL_UPDATECHECK=Off

WORKDIR /app
COPY IntuneDeployment.ps1 LICENSE ./
COPY code ./code
RUN rm -rf /app/code/tests \
 && useradd --system --uid 10001 --home-dir /app/data/home --shell /usr/sbin/nologin ica \
 && mkdir -p /app/data/home /app/data/tmp && chown -R ica:ica /app/data

USER ica
VOLUME ["/app/data"]
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s CMD curl -fsS http://127.0.0.1:8080/api/health > /dev/null || exit 1
CMD ["pwsh", "-NoLogo", "-NoProfile", "-File", "/app/IntuneDeployment.ps1"]
