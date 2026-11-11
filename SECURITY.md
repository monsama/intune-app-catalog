# Security

What the app exposes, what it keeps, and what it never does - for anyone
deciding whether to run it against their tenant.

## The local web server

The interface is a page served by the app itself, on this machine only.

- **Loopback only:** it listens on `127.0.0.1`, on a port from 17710 to
  17717 or a random one. Nothing outside the PC can connect.
- **A new token on every start.** The page gets it in the address's
  `#fragment`, which the browser never sends over the network. Every API
  call must carry it, and it is compared in constant time.
- **Only the app's own page can call the API.**
  - Requests addressed to any name other than `127.0.0.1`/`localhost` are
    refused, which stops DNS rebinding.
  - API calls must be JSON POSTs from the app's own origin. Another web
    page can't send them: a form can't send JSON.
- **Security headers on every response:**
  - a Content Security Policy that allows scripts from the app's own files
    only, and connections to nothing but this server;
  - no framing, no MIME sniffing, no caching, no referrer.
- **Fixed file list:** the page's files are served from a fixed list, so no
  part of a request is ever joined to a folder path.
- **Size limits:** request headers over 64 KB and bodies over 10 MB are not
  read, and at most 64 requests are handled at once.
- **It stops** when the app window closes, on Quit, or after 6 hours
  without the page.

Any program running as you on the same PC could read the token from the
app's console or the browser's command line. That is the same trust that
user already has over your files and your sign-ins.

## Microsoft Graph

- **The app's own sign-in is app-only with a certificate.** There is no
  client secret and no password, and the settings file holds only the
  Tenant ID, Client ID and certificate thumbprint.
- **Certificates the app creates** have a non-exportable private key.
  "Delete one..." deletes a certificate and its private key from this
  machine.
- **Your own account is used only by Upload certificate, Check
  certificates and Add required permissions.** You sign in interactively,
  limited to that one process, and with only the permission the action
  needs.
- **Every ID the page sends is checked to be a GUID before it goes into a
  Graph address:** app, group, member and script IDs. Group names in
  filters are escaped.

## Logs and messages

- **Upload addresses and tokens:** package uploads go to an Azure Storage
  address with a signature in it. The steps log only the address part,
  without the signature, and never log tokens.
- **A second filter** removes anything shaped like a secret before a line
  reaches the Activity log, the log file or an error on the page:
  - `sig=` signatures;
  - `Bearer` tokens and JSON Web Tokens;
  - `client_secret` / `password` / `access_token` values.

## Running steps

- **Plain commands only.** Background steps start as
  `powershell.exe -File code\Runner\Invoke-AppStep.ps1 -Spec <file>`, never
  with `-EncodedCommand` (which endpoint protection rightly treats as
  suspicious).
- **Parameters are values, not code.** They are passed as values and
  splatted, never parsed as PowerShell.
- **Winget:** the search text is passed as `--query` with Windows quoting,
  so it is always one argument and never an option.
- **The packaging tool** (IntuneWinAppUtil.exe) is downloaded from
  Microsoft only when you ask. Its Microsoft signature is checked before
  use.
- **Folder settings** must be full paths (a drive or `\\server\share`)
  without quotes, wildcards or control characters.

## Releases

The release zip is built by GitHub Actions from the tagged commit. Every
action the workflows use is pinned to an exact commit, not a movable tag,
and Dependabot proposes updates as pull requests. The scripts are signed
when the repository has a code-signing certificate (see the README).

## Test mode

`INTUNE_CATALOG_TEST_GRAPH` exists for the automated tests. When it names
a file at start-up, Graph is answered from that file and nothing signs
in. The app makes this obvious:
- the console says **TEST MODE** in red;
- the page shows a TEST MODE badge and banner;
- the settings file is never written.

## Not covered

- **The data you put in:** what the app deploys - install commands,
  detection scripts, platform scripts - runs on your devices as you wrote
  it. Review changes to the catalog as you would review code.
- **Execution policy:** releases can be signed (see the README), but a
  policy of `AllSigned` won't run the app, which writes its step helpers at
  run time.

## Reporting a problem

Please report security issues privately to the maintainer through the
contact on <https://monsama.ch>, not in a public issue.
