# Deploying the backend

<sup>[Configuring the playbook](configuring-playbook.md) > Deploying the backend</sup>

This document describes how the slovo-propovedi-admin **backend** is built and deployed by the playbook, and the things you should know when operating it.

## Overview

The backend is a **NestJS 10** application (Node 18, TypeScript) that serves the admin panel API and the Swagger documentation. It is deployed as a Docker container, **self-built from source** rather than pulled from a registry.

- Repository: `ssh://git@git.lightnode.ru/Slovo_Propovedi/slovo-propovedi-admin.git`
- Branch: `master`
- Image name: `slovo-backend:latest`
- Served on container port `3000` (exposed to the outside world only through Traefik)

The relevant playbook variables:

| Variable | Default |
| --- | --- |
| `slovo_backend_container_image_self_build` | `true` |
| `slovo_backend_container_image_self_build_repo` | `ssh://git@git.lightnode.ru/Slovo_Propovedi/slovo-propovedi-admin.git` |
| `slovo_backend_container_image_self_build_repo_version` | `master` |
| `slovo_backend_container_src_path` | `{{ slovo_backend_base_path }}/container-src` (i.e. `/slovo/backend/container-src`) |
| `slovo_backend_container_image` | `slovo-backend:latest` |

## Traefik routing

Both hostnames below are served by Traefik and route to the **same** backend container on port 3000:

| Hostname | Playbook variable | Purpose |
| --- | --- | --- |
| `admin.example.com` | `slovo_backend_hostname` | Admin panel UI + Swagger (main router `slovo-backend`) |
| `api.example.com` | `slovo_backend_api_hostname` | API requests — sermons, playlists CRUD, etc. (separate router `slovo-backend-api`) |

The API subdomain is **optional**: when `slovo_backend_api_hostname` is empty (the default), no API router is created and all traffic goes through `slovo_backend_hostname`. Both routers must point at the same `slovo-backend` service (port 3000), and `slovo_backend_api_hostname` must differ from `slovo_backend_hostname` (the playbook fails otherwise, to avoid two Traefik routers with identical Host rules).

## Self-build process

During installation (the `setup-slovo-backend` / `setup-all` tags), the playbook:

1. Ensures the repository directory (`{{ slovo_backend_container_src_path }}`) is owned by the `slovo` user.
2. Clones (or updates) the repository **as the `slovo` user** via `ansible.builtin.git`:
   ```sh
   git clone ssh://git@git.lightnode.ru/Slovo_Propovedi/slovo-propovedi-admin.git <src_path>
   ```
   on the `master` branch (`force: yes`, so a rerun always matches the remote).
3. Builds the image with Docker Buildx:
   ```sh
   docker buildx build \
     --tag=slovo-backend:latest \
     --file=<src_path>/backend/Dockerfile \
     <src_path>/backend
   ```
   The `backend/Dockerfile` is used and `backend/` is the build context.

The image is rebuilt whenever the git checkout changes or the `setup-all` tags are re-run, so updating the backend is as simple as re-running the playbook:

```sh
ansible-playbook -i inventory/hosts setup.yml --tags=setup-all,start
```

## Target host prerequisites

Because the image is self-built, the target host needs:

- **`git`** — for cloning the repository.
- **`docker buildx`** — for building the image (included with Docker ≥ 23; on older Docker installs the `docker-buildx-plugin` package may be required).
- **SSH access to `git.lightnode.ru` for the `slovo` user** — the clone runs as the `slovo` user, so that user's `~/.ssh` must contain a private key whose public key is authorized on `git.lightnode.ru`. Set this up **before** running the playbook, or the backend role will fail.

> [!WARNING]
> If the `slovo` user has no working SSH key for `git.lightnode.ru`, the `Ensure slovo-backend repository is present on self-build` task fails. This is the most common cause of backend installation failures.

## Environment variables

The backend reads its configuration from environment variables. The playbook renders them from your `vars.yml` into an env file at `{{ slovo_backend_base_path }}/env` (`/slovo/backend/env`), which the systemd unit passes to the container via `--env-file`.

| Env var | Playbook variable | Description |
| --- | --- | --- |
| `JWT_SECRET` | `slovo_backend_jwt_secret` | Signing secret for access tokens |
| `JWT_REFRESH_SECRET` | `slovo_backend_jwt_refresh_secret` | Signing secret for refresh tokens |
| `POSTGRES_HOST` | `slovo_backend_postgres_host` | PostgreSQL host — wired to the `slovo-postgres` container name |
| `POSTGRES_USER` | `slovo_backend_postgres_user` | PostgreSQL user |
| `POSTGRES_PASSWORD` | `slovo_backend_postgres_password` | PostgreSQL password |
| `POSTGRES_DB` | `slovo_backend_postgres_db` | PostgreSQL database name |
| `MINIO_ENDPOINT` | `slovo_backend_minio_endpoint` | MinIO server host — wired to the `slovo-minio` container name |
| `MINIO_MAIN_PORT_IN` | `slovo_backend_minio_main_port_in` | MinIO S3 API port inside the Docker network (`9000`) |
| `MINIO_ACCESS_KEY` | `slovo_backend_minio_access_key` | MinIO access key (must match `slovo_minio_root_user`) |
| `MINIO_SECRET_KEY` | `slovo_backend_minio_secret_key` | MinIO secret key (must match `slovo_minio_root_password`) |
| `MINIO_PUBLIC_URI` | `slovo_backend_minio_public_uri` | Public base URL of the MinIO S3 API, used to build public file links |

> [!IMPORTANT]
> - `POSTGRES_PORT` is **hardcoded to `5432`** in the backend source code (`db/typeorm.module.ts`) and is not configurable via env vars.
> - The MinIO credentials the backend uses (`slovo_backend_minio_access_key` / `slovo_backend_minio_secret_key`) are **wired automatically** from the MinIO root credentials (`slovo_minio_root_user` / `slovo_minio_root_password`) in `group_vars`, so they always match and there is no credential drift.

## Database

- The backend uses **PostgreSQL 18.4** (installed by the playbook's `galaxy/postgres` role).
- Data access is handled by **TypeORM** with `synchronize: true` — the backend **auto-creates and updates the schema on startup**.
- **No migrations are needed** and none are run by the playbook. The schema evolves automatically when the backend starts.

> [!NOTE]
> Because of `synchronize: true`, the backend must have permission to alter the schema. Avoid pointing it at a database you don't control, and take regular database backups (e.g. via `docker exec slovo-postgres pg_dump`).

## No health endpoint

The backend does **not** have a dedicated health-check endpoint. The closest endpoints are:

| Endpoint | Behavior |
| --- | --- |
| `GET /` | Returns app info (`Hello World!`) — confirms the process is up, no database dependency |
| `GET /auth/profile` | Returns the current admin profile — requires a valid JWT, exercises auth and database |

To handle crashes, the systemd unit (`slovo-backend.service`) uses `Restart=always` with `RestartSec=30`. If the process dies, systemd restarts it automatically.

## CORS

The backend allows the following origins (configured in `backend/src/main.ts`):

- `https://slovo-propovedi.ru`
- `https://www.slovo-propovedi.ru`
- `http://localhost:3000`
- `http://localhost:8081`
- `http://localhost:8082`

If you need to add more origins (e.g. another frontend domain), you must modify the backend code in `backend/src/main.ts` (`app.enableCors({ origin: [...] })`), rebuild, and redeploy. There is no playbook variable for this.

## JWT expiry

The `.env` file contains `JWT_ACCESS_EXPIRY` and `JWT_REFRESH_EXPIRY` variables, but the code **does not read them**. The expiry times are **hardcoded** in `backend/src/auth/auth.service.ts`:

- Access tokens: **30 minutes** (`expiresIn: '30m'`)
- Refresh tokens: **30 days** (`expiresIn: '30d'`)

To change these, modify the source code and redeploy — setting the env vars has no effect.

## Container user

The `backend/Dockerfile` sets `USER node` (uid 1000) only in the **dev** and **build** stages — the **production** stage does not, so the image would run as root by default. The playbook therefore runs the container with the systemd unit's `--user` flag set to the `slovo` user's uid/gid (see `slovo-backend.service.j2`), so the container always runs as a non-root user.

The `slovo` user's uid/gid are **auto-assigned by the system** when the playbook creates the user (exactly like the matrix reference playbook does) — they are not hardcoded to `1000`:

```yaml
# roles/custom/slovo-base/defaults/main.yml
slovo_user_uid: ~
slovo_user_gid: ~
```

After creating the user, the playbook discovers the actual assigned uid/gid and uses them for the `--user` flag. The env and labels files are written owned by `slovo:slovo` with mode `0640`, and the container runs as the same `slovo` uid, so the files are always readable by the container — regardless of the specific numeric uid/gid the system assigned.

> [!IMPORTANT]
> Do **not** set `slovo_user_uid`/`slovo_user_gid` unless you have a specific reason — they are auto-assigned so the container `--user` always matches the `slovo` user. If you do set them, make sure the uid/gid are not already taken on the server (a conflict makes the `slovo-base` role fail).

## No dev bind-mount in production

The original `docker-compose.yml` in the repository bind-mounts `./backend/:/app` into the container for **development** (so code changes take effect immediately). The playbook does **not** bind-mount — it uses the built image directly, so the code inside the container is the exact code built by Docker Buildx.

Additionally, the container is started with:

- `--read-only` — the root filesystem is read-only.
- `--tmpfs=/tmp:rw,noexec,nosuid,size=1024m` — a writable tmpfs at `/tmp` for temporary files (NestJS/Node may write temp files during uploads).
- `--cap-drop=ALL` — no capabilities.
- `--user={{ slovo_user_uid }}:{{ slovo_user_gid }}` — runs as the `slovo` user's auto-assigned uid/gid (the owner of the env/labels files).

## Troubleshooting

| Symptom | Likely cause | How to check / fix |
| --- | --- | --- |
| `slovo-backend.service` fails to start | Empty required env vars | `journalctl -u slovo-backend.service` — check for `JWT_SECRET`, `POSTGRES_PASSWORD`, etc. Fill them in `vars.yml` and re-run the playbook. |
| Self-build task fails | SSH key for `git.lightnode.ru` not set up for the `slovo` user | Add the `slovo` user's public key to `git.lightnode.ru` and re-run the playbook. |
| Backend can't connect to the database | Network join missing | `docker network inspect slovo-postgres` — the `slovo-backend` container must be attached. The joins come from `slovo_backend_container_additional_networks_auto` in `group_vars`. |
| MinIO auth errors on upload | Backend MinIO credentials mismatch | Ensure `slovo_backend_minio_access_key`/`slovo_backend_minio_secret_key` match `slovo_minio_root_user`/`slovo_minio_root_password`. |
