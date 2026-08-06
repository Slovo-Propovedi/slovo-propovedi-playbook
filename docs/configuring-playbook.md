# Configuring the playbook

<sup>Prerequisites > Configuring DNS > Configuring the playbook > Installing > Usage</sup>

This playbook deploys the **slovo-propovedi-admin** NestJS admin panel — a sermon/playlist management system with PostgreSQL, MinIO S3 storage, and an optional Adminer DB UI. It follows the [matrix-docker-ansible-deploy](https://github.com/spantaleev/matrix-docker-ansible-deploy) pattern: every service runs in its own Docker container managed by a systemd unit, with [Traefik](https://traefik.io/) as the reverse proxy in front of everything.

Here's what gets installed on your server:

| Service | Systemd unit | Container | Purpose |
| --- | --- | --- | --- |
| Backend (NestJS) | `slovo-backend.service` | `slovo-backend` | Admin panel API + docs (port 3000) |
| Frontend (Svelte 5) | `slovo-frontend.service` | `slovo-frontend` | Admin panel web UI (nginx-served SPA, port 8080) |
| Docs (standalone) | `slovo-docs.service` | `slovo-docs` | Standalone docs site (Swagger UI) + OpenAPI spec (nginx-served, port 8080) |
| PostgreSQL 18.4 | `slovo-postgres.service` | `slovo-postgres` | Primary database |
| MinIO | `slovo-minio.service` | `slovo-minio` | S3-compatible object storage (API port 9000, console port 9001) |
| Adminer (optional) | `slovo-adminer.service` | `slovo-adminer` | Web-based database administration (port 8080) |
| Traefik | `slovo-traefik.service` | `slovo-traefik` | Reverse proxy — TLS termination, Let's Encrypt, routing |

Related documentation:

- [Deploying the backend](deploying-backend.md) — details about the NestJS application and its self-built container.
- [Deploying the frontend](deploying-frontend.md) — details about the Svelte 5 SPA and its self-built container.
- [Configuring Traefik](configuring-traefik.md) — details about the reverse proxy.

## Prerequisites

These requirements need to be set up manually **before** running the playbook.

On your **control machine** (where you run Ansible):

- **Ansible 2.16+**. It's used to run the playbook and configure your server for you.
- **`git`**, to clone this playbook and the upstream Ansible roles.
- A strong password/secret generator (e.g. `pwgen -s 64 1`) — the playbook requires you to provide strong secrets in `vars.yml`.

On the **target server**:

- A server running a **systemd-based Linux distribution** (Debian/Ubuntu recommended).
- **Docker** installed — or let the playbook install it for you via the `geerlingguy.docker` role (keep `docker_installation_enabled: true`).
- **Python 3 with the `bcrypt` module** — required for admin user seeding (e.g. `apt-get install python3-bcrypt`, or `pip3 install bcrypt`).
- **`git` and `docker buildx`** — the backend is self-built from source, so both must be present on the target host.
- **SSH access to `git.lightnode.ru`** — the backend repository is cloned over SSH. Set up an SSH key for the `slovo` user on the target host and authorize that public key on `git.lightnode.ru` **before** running the playbook.
- **`root` access** (or a user capable of elevating to root via `sudo`), since the playbook runs with `become: true`.
- Properly configured DNS records (see the next section).

> [!WARNING]
> The backend container image is **self-built** from a private git repository. If the `slovo` user cannot SSH into `git.lightnode.ru`, the `slovo-backend` role will fail during installation. Set up the SSH keys first.

## DNS

Every service is served by Traefik on ports 80/443, so all of the records below point to the **same server IP**. Create the following A (IPv4) / AAAA (IPv6) records:

| Record | Points to | Used for |
| --- | --- | --- |
| `admin.example.com` | your server's IP | Backend (NestJS API + docs) |
| `api.example.com` | your server's IP | API requests (sermons, playlists CRUD) |
| `admin-app.example.com` | your server's IP | Frontend (admin panel web UI) |
| `docs.example.com` | your server's IP | Standalone docs site (Swagger UI) |
| `minio-api.example.com` | your server's IP | MinIO S3 API |
| `minio-console.example.com` | your server's IP | MinIO console |
| `adminer.example.com` | your server's IP | Adminer (only needed if you enable it) |

Replace `example.com` with your own domain throughout this guide.

## Adjusting vars.yml

The playbook already wires all cross-service variables together in `group_vars/slovo_servers/main.yml` (Docker networks, service dependencies, container names, etc.). You only need to provide your own values — hostnames, secrets, and credentials.

### 1. Prepare the inventory and vars files

```sh
# Point the inventory at your server
# (inventory/hosts already ships with a commented-out template; examples/hosts is a copy of it)
nano inventory/hosts

# Copy the sample vars file and edit it for your host
mkdir -p inventory/host_vars/your-server.example.com
cp examples/vars.yml inventory/host_vars/your-server.example.com/vars.yml
nano inventory/host_vars/your-server.example.com/vars.yml
```

> [!NOTE]
> The sample `examples/vars.yml` is minimal: the Let's Encrypt email is left commented out. The backend's MinIO credentials are wired automatically from the MinIO root credentials in `group_vars/slovo_servers/main.yml`, so you don't need to set `slovo_backend_minio_*` yourself — but you must provide `slovo_minio_root_user`/`slovo_minio_root_password`. Make sure your `vars.yml` ends up with everything required for your setup.

> [!TIP]
> The `inventory` directory is ignored via `.gitignore`, so you can safely keep your configuration and secrets out of version control. If you use [Ansible Vault](https://docs.ansible.com/ansible/latest/vault_guide/index.html) for secrets, encrypt the vars file with `ansible-vault encrypt ...` and add `--ask-vault-pass` to the Ansible commands below.

### 2. Minimal configuration

Here is the minimal set of variables to put in your `vars.yml` (adjust hostnames and secrets to your environment):

```yaml
# ──────────────────────────────────────────────
# Base path (where all slovo data lives on the server)
# ──────────────────────────────────────────────
slovo_base_data_path: /slovo

# ──────────────────────────────────────────────
# Reverse proxy
# ──────────────────────────────────────────────
slovo_playbook_reverse_proxy_type: playbook-managed-traefik

# Email used for Let's Encrypt certificate notifications (required for automatic TLS)
traefik_config_certificatesResolvers_acme_email: admin@example.com

# ──────────────────────────────────────────────
# Backend hostname + JWT secrets
# ──────────────────────────────────────────────
slovo_backend_hostname: admin.example.com
# Optional: separate subdomain for API requests (sermons, playlists CRUD).
# Routes to the same backend container on port 3000; leave empty to serve
# everything through slovo_backend_hostname.
slovo_backend_api_hostname: api.example.com
slovo_backend_jwt_secret: CHANGE_ME_strong_random_secret
slovo_backend_jwt_refresh_secret: CHANGE_ME_strong_random_secret

# ──────────────────────────────────────────────
# Frontend hostname
# ──────────────────────────────────────────────
slovo_frontend_hostname: admin-app.example.com

# ──────────────────────────────────────────────
# Docs hostname
# ──────────────────────────────────────────────
slovo_docs_hostname: docs.example.com

# ──────────────────────────────────────────────
# PostgreSQL credentials
# ──────────────────────────────────────────────
slovo_backend_postgres_user: slovo
slovo_backend_postgres_password: CHANGE_ME_strong_random_password
slovo_backend_postgres_db: slovo

# ──────────────────────────────────────────────
# MinIO credentials + hostnames
# ──────────────────────────────────────────────
slovo_minio_hostname: minio-api.example.com
slovo_minio_console_hostname: minio-console.example.com
slovo_minio_root_user: slovo-minio
slovo_minio_root_password: CHANGE_ME_strong_random_password

# Credentials the backend uses to talk to MinIO are wired automatically from the
# MinIO root credentials above in group_vars (slovo_backend_minio_*).
# You only need to set them here if you want to override that wiring.

# ──────────────────────────────────────────────
# Adminer (optional — disable if not needed)
# ──────────────────────────────────────────────
slovo_adminer_enabled: true
slovo_adminer_hostname: adminer.example.com

# ──────────────────────────────────────────────
# Admin user seeding (used by the ensure-slovo-users-created tag)
# ──────────────────────────────────────────────
slovo_admin_user_enabled: true
slovo_admin_user_username: admin
slovo_admin_user_email: admin@example.com
slovo_admin_user_password: CHANGE_ME_admin_password
```

### What each section means

- **Base path** — `slovo_base_data_path` is the directory on the server where all service data lives (`/slovo` by default). Each service stores its config, env files, and data under it (e.g. `/slovo/backend`, `/slovo/postgres`, `/slovo/minio`, `/slovo/traefik`, `/slovo/adminer`).

- **Reverse proxy** — `slovo_playbook_reverse_proxy_type: playbook-managed-traefik` enables the playbook-managed Traefik instance. See [Configuring Traefik](configuring-traefik.md) for details.

- **PostgreSQL** — the `slovo_backend_postgres_*` variables define the database user, password, and database name. The postgres role creates the database and user on startup (see `postgres_managed_databases_auto` in `group_vars`). The backend reaches PostgreSQL at the container name `slovo-postgres` (`POSTGRES_HOST` is wired automatically — you don't normally set it). The PostgreSQL port is hardcoded to `5432` in the backend source code.

- **Backend hostname + JWT secrets** — `slovo_backend_hostname` is the public hostname of the API. The two JWT secrets must be strong random strings; they sign access and refresh tokens respectively. Never reuse them across environments. Optionally, `slovo_backend_api_hostname` exposes a **second subdomain** (e.g. `api.example.com`) for API requests; it routes to the same backend container on port 3000 via a separate Traefik router named `slovo-backend-api`. When left empty, no API router is created and everything is served through `slovo_backend_hostname`.

- **Frontend hostname** — `slovo_frontend_hostname` is the public hostname of the admin panel web UI (e.g. `admin-app.example.com`, a Svelte 5 SPA served by nginx on port 8080). The SPA calls the API through the relative `/api` path; the frontend's nginx proxies those requests to the backend container on the shared Docker network. See [Deploying the frontend](deploying-frontend.md) for details.

- **Docs hostname** — `slovo_docs_hostname` is the public hostname of the standalone docs site (e.g. `docs.example.com`). It is a static site self-built from the `slovo-propovedi-docs` repository and served by nginx on port 8080 in a read-only container. The backend's `DOCS_UI_ORIGIN` is wired automatically to `https://{{ slovo_docs_hostname }}` (when docs is enabled) so the backend's CORS allows the docs site to fetch the OpenAPI spec. If the backend should also serve its own spec endpoint, set `slovo_backend_docs_enabled: true` in your vars.

- **MinIO** — `slovo_minio_root_user`/`slovo_minio_root_password` are the MinIO server's root credentials. The backend's MinIO credentials (`slovo_backend_minio_access_key`/`slovo_backend_minio_secret_key`) and public S3 URI (`slovo_backend_minio_public_uri`) are **wired automatically** from the root credentials and `slovo_minio_hostname` in `group_vars/slovo_servers/main.yml`, so they always match and there is no credential drift. The endpoint (`slovo-minio`) and API port (`9000`) are also wired automatically.

- **Adminer (optional)** — a lightweight database web UI. Set `slovo_adminer_enabled: false` (or remove the `slovo_adminer_*` variables) to skip it entirely. Adminer asks for credentials manually in the browser — connect to server `slovo-postgres` with the PostgreSQL credentials above.

- **Admin user seeding** — the playbook can insert the first admin user into the database. This is a **separate, on-demand step** (see below), and it requires `slovo_admin_user_username`, `slovo_admin_user_email`, and `slovo_admin_user_password` to be set. Login is by **username** (`slovo_admin_user_username`); the email is retained in the database for display only. For existing installs, `slovo_admin_user_username` MUST match the username already present in the database — otherwise `ON CONFLICT (username)` would attempt to insert a second row with the same email and hit the email unique constraint.

> [!NOTE]
> The `group_vars/slovo_servers/main.yml` file wires most cross-service settings (container names, networks, dependencies) for you. If you override a value there, make sure you know what it feeds into — for example, `slovo_user_uid`/`slovo_user_gid` are auto-assigned by the system and feed into every container's `--user` flag (see [Deploying the backend](deploying-backend.md)).

## Installing

### 1. Install the Galaxy roles

The playbook depends on several upstream Ansible roles (Docker, Traefik, PostgreSQL, systemd helpers) declared in `requirements.yml`:

```sh
just roles
```

> [!NOTE]
> `setup.yml` references these roles with the `galaxy/...` prefix (e.g. `role: galaxy/traefik`), which Ansible resolves relative to the playbook's `roles/` directory. `just roles` installs them into `roles/galaxy/` to match that layout.
>
> Without `just`, install them directly:
>
> ```sh
> rm -rf roles/galaxy && ansible-galaxy install -r requirements.yml -p roles/galaxy/ --force
> ```

### 2. Run the playbook

```sh
just setup-all
```

This installs all services (Docker, PostgreSQL, MinIO, backend, frontend, docs, Adminer, Traefik) and starts them.

> [!NOTE]
> Without `just`, run the equivalent `ansible-playbook` command:
>
> ```sh
> ansible-playbook -i inventory/hosts setup.yml --tags=setup-all,start
> ```
>
> - If you don't use SSH keys for authentication, add `--ask-pass` to all Ansible commands.
> - If you log in as a non-root user and become root via sudo, add `-K` (`--ask-become-pass`).
> - If your vars file is encrypted with Ansible Vault, add `--ask-vault-pass`.

### 3. Create the admin user (separate step)

The admin user is **not** created during installation. Run this as its own step (this is why the role intentionally does not have the `setup-all` tag):

```sh
just ensure-admin-user
```

> [!NOTE]
> Without `just`, run the equivalent `ansible-playbook` command:
>
> ```sh
> ansible-playbook -i inventory/hosts setup.yml --tags=ensure-slovo-users-created
> ```

This waits for PostgreSQL to be ready, generates a bcrypt hash of `slovo_admin_user_password` on the target host (hence the Python `bcrypt` prerequisite), and inserts the admin user into the database. If the username already exists, the task reports it and does nothing.

## Usage

After installation, everything is available over HTTPS:

| What | URL |
| --- | --- |
| Admin panel UI | `https://admin-app.example.com` |
| Backend API | `https://admin.example.com` |
| API documentation | `https://docs.example.com` |
| MinIO console | `https://minio-console.example.com` |
| Adminer | `https://adminer.example.com` (if enabled) |

You can check service status and logs on the server:

```sh
systemctl status slovo-backend slovo-postgres slovo-minio slovo-traefik slovo-adminer
journalctl -u slovo-backend.service -f
```

## Troubleshooting

| Symptom | Likely cause | How to check / fix |
| --- | --- | --- |
| Backend won't start | Missing env vars (`JWT_SECRET`, `POSTGRES_PASSWORD`, etc.) | Check `journalctl -u slovo-backend.service` — the most common cause is empty required env vars. Fill them in `vars.yml` and re-run `ansible-playbook -i inventory/hosts setup.yml --tags=setup-all,start`. |
| Backend can't reach PostgreSQL | Backend is not on the postgres Docker network | Verify connectivity: `docker network inspect slovo-postgres` — the `slovo-backend` container must appear in the container list. Network joins are wired via `slovo_backend_container_additional_networks_auto` in `group_vars`. |
| Traefik returns 502 | `traefik.docker.network` label mismatch | Ensure the service's `traefik.docker.network` label matches the shared Traefik network name (`traefik`). Traefik can only reach a container through a network they share. See [Configuring Traefik](configuring-traefik.md). |
| Admin user creation fails | `python3-bcrypt` missing, or PostgreSQL not accepting connections | Verify `python3 -c "import bcrypt"` works on the target host, and that PostgreSQL is up (`docker exec slovo-postgres pg_isready -U slovo`). Then re-run `ansible-playbook -i inventory/hosts setup.yml --tags=ensure-slovo-users-created`. |
| Self-build of the backend image fails | SSH key for `git.lightnode.ru` not set up for the `slovo` user | Check that the `slovo` user's SSH public key is authorized on `git.lightnode.ru` before running the playbook. The clone happens as the `slovo` user on the target host (see [Deploying the backend](deploying-backend.md)). |
