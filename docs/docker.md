# The server version (Docker)

The same app as the desktop version, in a Linux container on a server: people open it in the browser
(`https://apps.example.ch`), sign in with the admin password, and the nightly run happens on the server - no PC
has to stay on. It runs next to NOBS Inventory and uses its shared HTTPS proxy.

## Set up

On the server that runs NOBS Inventory (Docker Engine with the Compose plugin):

    git clone https://github.com/monsama/intune-app-catalog /opt/intune-app-catalog && cd /opt/intune-app-catalog
    sudo ICA_HOST=apps.example.ch ./deploy-ica.sh

The script

1. writes `.env` (the name, the image, the time zone) and `secrets/admin_password` (generated),
2. pulls `ghcr.io/monsama/intune-app-catalog:<version>` (it builds the image when the pull isn't possible),
3. starts the app and waits until it is healthy,
4. writes the site `proxy/sites/intune-catalog.caddy` into NOBS Inventory's folder (`NOBS_DIR`, default
   `/opt/nobs-inventory`) and restarts `nobs-proxy`,
5. shows the admin password once.

The DNS name must point at the server. The site uses the proxy's default certificate until it has its own -
NOBS Inventory's `sudo ./scripts/install-cert.sh intune-catalog /path/to/apps.pem` installs one.

Without NOBS Inventory's proxy: `sudo ./deploy-ica.sh --no-proxy`, and forward `https://<name>` to
`intune-app-catalog:8080` on the Docker network `nobs-proxy` from the proxy you have.

## First steps

1. Sign in with the admin password.
2. **Settings > Connection**: tenant and client ID, then the certificate:
   - **Import a .pfx...** - the certificate the app registration already has (exported with its private key from
     the PC the desktop app runs on: `certmgr.msc` > Personal > the certificate > Export, with the private key), or
   - **Create new certificate...**, then **Download .cer** and add it in Entra ID: the app registration >
     Certificates & secrets > Certificates > Upload certificate.
   The API permissions are added in Entra ID by hand too (API permissions > Add a permission, then Grant admin
   consent) - Diagnostics > Check permissions lists every one the app uses. The server can't sign you in to Entra
   ID for these two, as the desktop app does.
3. **Test connection**, Save.
4. **Settings > Packaging & folders > Build init.intunewin** - the shared package every Winget app deploys with.
5. Your apps: they are in Intune already from the desktop version - **Checks > Run checks**, tick "In Intune, not in
   the catalog", **Add to catalog**. Their settings and groups come along. Apps with their own installer need it
   again (Add apps > Installer), so updates can be packaged here.
6. **Settings > Nightly run & alerts > Schedule**: the nightly run (and the fast-track run every 2 hours) now runs
   on the server, at the time set there.

## Sign-in

One admin, one session: signing in ends the session that is open in another browser, which goes back to the
sign-in page and says so. A session also ends after 2 hours without use (`ICA_IDLE_MINUTES`) and 12 hours after
sign-in (`ICA_SESSION_HOURS`). Five wrong passwords within a minute: no password is checked for a minute.

To change the password: write the new one (at least 12 characters) into `secrets/admin_password`, then
`docker compose restart app`.

## What is different from the desktop version

| Desktop (Windows) | Server version |
| --- | --- |
| winget.exe answers search, versions and details | winget's package index from cdn.winget.microsoft.com, read on the server (refreshed every 6 hours) |
| Windows scheduled tasks for the nightly run | the server's own schedule (Settings > Nightly run & alerts) |
| Certificate in the Windows store; Upload to Entra / Add permissions sign you in | Certificate in the server's store (data volume); import a .pfx or create one; add .cer and permissions in Entra ID by hand |
| IntuneWinAppUtil.exe or built in | built in only |
| Windows Sandbox test, Detection from an app on this PC, Read this PC's apps, Open folder | not there |
| The page on 127.0.0.1 with a token from the app window | the page on https://<name>, with the admin sign-in |

Everything else - the catalog, Send to Intune, groups, Checks, Updates and releases, platform scripts - works the
same way.

## Operations

| Task | Command |
| --- | --- |
| Update | `sudo ./scripts/update-ica.sh` (git pull, backup, that version's image; goes back when it isn't healthy) |
| Update to a release | `sudo ./scripts/update-ica.sh 2.28.1` |
| Back up | `sudo ./scripts/backup-ica.sh` -> `backup/intune-app-catalog-<time>.tar.gz` (kept 14 days) - it holds the certificate's private key: keep it private |
| Logs | `docker compose logs -f app`; the app's own: `docker exec intune-app-catalog ls /app/data/logs` |
| Test a build | `./scripts/docker-smoke.sh` (builds, starts, checks sign-in, takeover, names, winget's index) |

Everything the app keeps is on the volume `intune-app-catalog-data` (`/app/data`): the catalog, packages, settings,
logs, reports and the certificate store. The container itself is read-only and runs without rights.
