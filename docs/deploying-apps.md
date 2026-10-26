# Deploying the applications

<sup>This playbook provisions **shared infrastructure only**. The applications deploy themselves.</sup>

## Split of responsibility

| Concern | Owner | How |
| --- | --- | --- |
| Host baseline: swap, the `slovo` system user/group, Docker, the `slovo-constrained` buildx builder | **this playbook** | `just setup-all` |
| Data + edge services: PostgreSQL, PgBouncer, MinIO, Adminer, Traefik | **this playbook** | `just setup-all` |
| The application containers (API, admin SPA, docs site, landing site) | **each app repo** | its own `scripts/vps-deploy.sh`, triggered by a `v*` tag on Forgejo Actions |

The playbook has **no role** for any application. Conversely, the app deploy
scripts **never provision infrastructure** — they verify that the playbook-owned
pieces exist and fail fast with a clear message if they do not. Run this playbook
against a host **before** the first application deploy.

## The applications

| App | Repository | Container / systemd unit | Depends on (beyond the base) |
| --- | --- | --- | --- |
| Backend API | `slovo-propovedi-backend` | `slovo-backend` | `slovo-postgres`, `slovo-pgbouncer`, `slovo-minio`, Traefik |
| Admin SPA | `slovo-propovedi-admin` | `slovo-frontend` | Traefik |
| Docs site (Swagger UI) | `slovo-propovedi-docs` | `slovo-docs` | Traefik |
| Landing / site apex | `slovo-propovedi-landing` | `slovo-landing` | Traefik |
| Web app (PWA) | `slovo-propovedi-mobile` (`scripts/vps-deploy-web.sh`) | `slovo-web` | Traefik |

No app provisions shared infrastructure, and no app needs an `ACME_EMAIL`
secret — Traefik and its ACME resolver are configured by the playbook's
`traefik` role. (The mobile web deploy used to auto-provision its own Traefik;
it now only verifies, like the others.)

## Forgejo variables and secrets — registry

This is the single list of every Forgejo Actions variable and secret the
`Slovo_Propovedi` repositories use (`Slovo_Propovedi` → Settings → Actions →
Variables / Secrets). They exist **only for the apps' release workflows**,
which have no access to the playbook's vault, and are created **manually**
(there is no API automation in this playbook).

They are **not** a second source of truth. Everything playbook-side — IPs,
domains, ports, container names, credentials — lives in `inventory/` /
`host_vars` / `group_vars` plus the private vault. Rows marked *playbook* below
are **references** to playbook values and must be kept in sync **manually**.
Nothing from the vault is duplicated into Forgejo except where noted.

Rule of thumb: a value used by two or more repositories is an **org**
variable/secret (one place to change it); a value only one repository needs
stays at **repo** level. Every app workflow validates its required variables
before deploying and fails with the variable name, so a missing or malformed
value never reaches the VPS. No app script carries a hardcoded fallback for
these values.

### Org variables

| Variable | Value / source | Used by |
| --- | --- | --- |
| `LANDING_HOSTNAME` | site apex hostname | backend (CORS), landing, mobile |
| `WWW_HOSTNAME` | `www.` hostname, redirected to the apex | landing |
| `WEB_HOSTNAME` | web-app hostname | backend (CORS), landing, mobile |
| `DOCS_HOSTNAME` | docs (Swagger UI) hostname | backend, docs, landing |
| `BACKEND_API_HOSTNAME` | API hostname | backend, docs, mobile |
| `REPOSITORY_URL` | primary Forgejo origin, e.g. `https://git.lightnode.ru` (bare https origin, no path) | landing, mobile |
| `REPOSITORY_ORG` | org on the primary Forgejo, `Slovo_Propovedi` | landing, mobile |
| `MIRROR_CODEBERG_URL` | `https://codeberg.org` (bare https origin) | landing, mobile |
| `MIRROR_CODEBERG_ORG` | org on Codeberg, `Slovo_Propovedi` | landing, mobile |
| `MIRROR_GITHUB_ORG` | org on GitHub, `Slovo-Propovedi` — **hyphen**, unlike Forgejo/Codeberg; GitHub hosts are fixed | landing, mobile |
| `MOBILE_REPOSITORY_NAME` | `slovo-propovedi-mobile` | landing, mobile |
| `APK_SIGNER_SHA256` | SHA-256 of the mobile release-key certificate (64 hex, as `apksigner verify --print-certs` prints it); comma-separated `old,new` during a key rotation. Public value | landing (refresh publishes only matching APKs), mobile (release refuses a differently signed APK) |
| `TRAEFIK_NETWORK` | `traefik` (*playbook* `slovo_playbook_reverse_proxy_container_network`, `roles/custom/slovo-base/defaults/main.yml`) | backend, docs, landing, mobile |
| `TRAEFIK_SERVICE` | `slovo-traefik.service` (*playbook* `group_vars/slovo_servers/main.yml`) | backend, docs, landing, mobile |
| `BUILDX_BUILDER` | `slovo-constrained` (*playbook* `slovo_buildx_builder_name`, `roles/custom/slovo-buildx/defaults/main.yml`) | backend, docs, landing, mobile |
| `RENOVATE_GIT_AUTHOR` | author of Renovate commits, e.g. `Renovate Bot <renovate@slovo-propovedi.ru>`; mobile also derives its DCO `Signed-off-by` trailer from it | all repos (incl. this playbook) |

### Repo variables (single consumer)

| Variable | Value / source | Repo |
| --- | --- | --- |
| `POSTGRES_HOST` / `POSTGRES_PORT` / `POSTGRES_USER` / `POSTGRES_DB` | `slovo-pgbouncer` / `5432` / `slovo` / `slovo` (*playbook*) | backend |
| `MINIO_ENDPOINT` / `MINIO_MAIN_PORT_IN` | `slovo-minio` / `9000` (*playbook*) | backend |
| `POSTGRES_NETWORK` / `MINIO_NETWORK` | `slovo-postgres` / `slovo-minio` (*playbook* `group_vars/slovo_servers/main.yml`) | backend |
| `INTERNAL_PORT` | `3000` — backend container port Traefik targets | backend |
| `MINIO_API_HOSTNAME` | public MinIO hostname (*playbook* `slovo_minio_hostname`) | backend |
| `EXPO_PUBLIC_OTA_URL`, `EXPO_PUBLIC_XPREM_APP_ID`, `EXPO_PUBLIC_XPREM_CHANNEL_NAME`, `EXPO_PUBLIC_XPREM_BRANCH_NAME` | OTA / xprem settings (see [configuring-playbook-xprem.md](configuring-playbook-xprem.md)) | mobile |
| `RELEASE_KEEP_COUNT` | how many Codeberg release assets to keep (default 10) | mobile |

These may live at org level today; that is harmless, the table records who
actually reads them.

### Secrets

| Secret | Scope | Value | Used by |
| --- | --- | --- | --- |
| `VPS_HOST`, `VPS_SSH_USER`, `VPS_SSH_PRIVATE_KEY` | org | SSH target and key for the deploy | backend, docs, landing, mobile |
| `VPS_SSH_KNOWN_HOSTS` | org | pinned VPS host key: `ssh-keyscan <VPS_HOST> 2>/dev/null` output, verified against `ssh-keygen -lf /etc/ssh/ssh_host_*_key.pub` on the server; update after a VPS reinstall | backend, docs, landing, mobile |
| `MINIO_ACCESS_KEY` | org today; only the backend reads it, so repo level would be tighter | MinIO root user — the one vault value an app needs | backend |
| `BACKEND_JWT_SECRET`, `BACKEND_JWT_REFRESH_SECRET`, `BACKEND_POSTGRES_PASSWORD`, `BACKEND_MINIO_SECRET_KEY` | repo | backend runtime secrets | backend |
| `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` | repo | release signing key | mobile |
| `XPREM_EOO_TOKEN` | repo | xprem OTA publish token | mobile |
| `XPREM_ADMIN_EMAIL`, `XPREM_ADMIN_PASSWORD` | repo (optional) | xprem dashboard login for the cleanup workflow; without them `xprem-cleanup.yml` only warns and skips | mobile |
| `MIRROR_GITHUB_TOKEN`, `MIRROR_CODEBERG_TOKEN` | repo | write tokens for the release mirrors | mobile |
| `RENOVATE_TOKEN`, `RENOVATE_GITHUB_COM_TOKEN` | org | Renovate bot access | all repos |

Why the single-consumer secrets stay at **repo** level: an org secret is
handed to the workflows of *every* repository in the org. A compromised
dependency running in, say, the docs repo's CI (Renovate branches run with
secrets) could then read the Android signing key — enough to ship an "update"
Android accepts as genuine — or the backend's database password. Only values
two or more repositories need belong at org level.

Not used any more (safe to delete if still present): `MIRROR_GITHUB_LATEST_RELEASE_URL`,
`MIRROR_GITHUB_SCREENSHOTS_RAW_URL` (landing derives both from
`MIRROR_GITHUB_ORG` + `MOBILE_REPOSITORY_NAME`), `ACME_EMAIL`,
`REPOSITORY_API_TOKEN`, `GITHUB_MIRROR_TOKEN` (the landing refresh reads the
public repositories anonymously).

The landing release workflow writes the repository coordinates and
`APK_SIGNER_SHA256` into `/etc/default/slovo-landing` on every deploy; the
sandboxed refresh units read it via `EnvironmentFile=`. Do **not** create or
edit that file manually — the workflow owns it.

## What each app deploy script expects from the playbook

- Docker installed and running.
- The `slovo` user and group (created by the `slovo-base` role). The apps run
  their containers as this non-root uid/gid.
- The buildx builder named by `BUILDX_BUILDER` (`slovo-constrained`, created by
  the `slovo-buildx` role) — a single shared, resource-capped
  `docker-container` builder for on-VPS image builds.
- The Traefik unit named by `TRAEFIK_SERVICE` active and the Docker network
  named by `TRAEFIK_NETWORK` present. The app scripts take all three names from
  the org variables above — rename something here, update the variable there.
- The backend additionally requires `slovo-postgres.service`,
  `slovo-pgbouncer.service`, `slovo-minio.service` and the `slovo-postgres` /
  `slovo-minio` Docker networks.

If any of these is missing, the app deploy aborts with
`Provision it first: just setup-all` rather than half-provisioning the host.

## Ports and wiring

- PgBouncer listens on **5432** (not 6432) inside its container, matching the
  backend's Forgejo org var `POSTGRES_PORT=5432`. The backend reads
  `POSTGRES_HOST` / `POSTGRES_PORT` / `POSTGRES_USER` / `POSTGRES_DB` /
  `MINIO_ENDPOINT` / `MINIO_MAIN_PORT_IN` from org-level vars, so these can be
  changed — but the org vars must be updated to match (see the org-level table
  above). See `roles/custom/slovo-pgbouncer/defaults/main.yml`.
- The backend reaches the database via `slovo-pgbouncer:5432` on the
  `slovo-postgres` Docker network, and MinIO via `slovo-minio:9000` on the
  `slovo-minio` network.

## Related documentation

- [Configuring the playbook](configuring-playbook.md)
- [Configuring Traefik](configuring-traefik.md)
