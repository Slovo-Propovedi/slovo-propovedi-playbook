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

Each app repo holds its own Forgejo secrets (`VPS_SSH_PRIVATE_KEY`, `VPS_HOST`,
`VPS_SSH_USER`) and variables (its public hostname). The `ACME_EMAIL` secret is
**not** used by the apps — Traefik and its ACME resolver are configured by the
playbook's `traefik` role.

## Recommended Forgejo org-level vars and secrets

Org-level vars and secrets (`Slovo_Propovedi` → Settings → Actions →
Variables / Secrets) exist **only for the apps' release workflows**, which do
not have access to the playbook's vault. They are created **manually** in the
Forgejo org settings (there is no API automation in this playbook).

They are **not** a second source of truth. The playbook is private and runs
locally only; everything playbook-side — IPs, domains, ports, container names,
credentials — lives in `inventory/` / `host_vars` / `group_vars` plus the
private vault (`host_vars/vars.yml`: postgres/admin/minio root passwords).
Nothing from the vault is duplicated into Forgejo. Org vars are **references**
to playbook values and must be kept in sync **manually**, only where an app
workflow needs the same value the playbook already defines.

Org **variables** (values are references from this playbook — keep them
matching `host_vars` / `group_vars`):

| Var | Value (per this playbook) |
| --- | --- |
| `POSTGRES_HOST` | `slovo-pgbouncer` |
| `POSTGRES_PORT` | `5432` |
| `POSTGRES_USER` | `slovo` |
| `POSTGRES_DB` | `slovo` |
| `MINIO_ENDPOINT` | `slovo-minio` |
| `MINIO_MAIN_PORT_IN` | `9000` |
| `WWW_HOSTNAME` | landing's public hostname (landing only) |
| `REPOSITORY_URL` | базовый URL инстанса с репозиториями (сейчас git.lightnode.ru) |
| `MIRROR_GITHUB_LATEST_RELEASE_URL` | `https://api.github.com/repos/Slovo-Propovedi/slovo-propovedi-mobile/releases/latest` |
| `MIRROR_GITHUB_SCREENSHOTS_RAW_URL` | `https://raw.githubusercontent.com/Slovo-Propovedi/slovo-propovedi-mobile/main/assets/screenshots` |
| `RENOVATE_GIT_AUTHOR` | author Renovate commits as |

`REPOSITORY_URL`, `MIRROR_GITHUB_LATEST_RELEASE_URL` and `MIRROR_GITHUB_SCREENSHOTS_RAW_URL` are also written by the
landing release workflow into `/etc/default/slovo-landing` on the VPS on
every deploy — the timer-driven refresh scripts (`vps-refresh-apk`,
`vps-refresh-screenshots`) source that file. Do **not** create it manually:
the workflow owns it.

Org **secrets**:

| Secret | Value |
| --- | --- |
| `MINIO_ACCESS_KEY` | the MinIO root user (from vault — this is the one vault value an app workflow needs, because workflows have no vault access) |

`VPS_HOST`, `VPS_SSH_USER`, `VPS_SSH_PRIVATE_KEY` stay **per-repo** secrets
(each app repo holds its own copy) — do **not** move them to the org level.

## What each app deploy script expects from the playbook

- Docker installed and running.
- The `slovo` user and group (created by the `slovo-base` role). The apps run
  their containers as this non-root uid/gid.
- The `slovo-constrained` buildx builder (created by the `slovo-buildx` role) —
  a single shared, resource-capped `docker-container` builder for on-VPS image
  builds.
- `slovo-traefik.service` active and the `traefik` Docker network present.
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
