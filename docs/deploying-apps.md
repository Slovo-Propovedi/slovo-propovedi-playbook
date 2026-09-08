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

- PgBouncer listens on **5432** (not 6432) inside its container, because the
  backend hardcodes `POSTGRES_PORT=5432` and cannot be reconfigured. See
  `roles/custom/slovo-pgbouncer/defaults/main.yml`.
- The backend reaches the database via `slovo-pgbouncer:5432` on the
  `slovo-postgres` Docker network, and MinIO via `slovo-minio:9000` on the
  `slovo-minio` network.

## Related documentation

- [Configuring the playbook](configuring-playbook.md)
- [Configuring Traefik](configuring-traefik.md)
