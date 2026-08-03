# slovo-propovedi-playbook

Ansible playbook for deploying the slovo-propovedi-admin NestJS admin panel.

This playbook follows the [matrix-docker-ansible-deploy](https://github.com/spantaleev/matrix-docker-ansible-deploy) pattern: every service runs in a Docker container managed by systemd, with Traefik as the reverse proxy in front of everything.

## Features

- **Backend (NestJS 10)** — the slovo-propovedi-admin panel API
- **Frontend (Svelte 5)** — the admin panel web UI, served by nginx
- **Swagger UI (standalone)** — self-hosted Swagger documentation + OpenAPI spec
- **PostgreSQL 18.4** — primary database
- **MinIO** — S3-compatible object storage
- **Adminer** — web-based database administration
- **Traefik** — reverse proxy with automatic Let's Encrypt certificates
- **systemd-managed containers** — each service runs as its own systemd unit

## Prerequisites

- **Ansible 2.16+** on the control machine
- **just** — the command runner used by the `justfile` (see [just](https://github.com/casey/just)). If you don't have it, you can run the raw `ansible-playbook` commands instead (see the note in the quick start below)
- **Docker** on the target host
- **Python 3 with the `bcrypt` module** on the target host (required for admin user seeding)
- **git + docker buildx** on the target host (required for building images from source — backend and Swagger UI)
- **SSH access to git.lightnode.ru** from the target host (required for cloning the backend and Swagger UI repositories)

## Quick start

1. **Clone this repository:**

   ```bash
   git clone <your-repo-url> slovo-propovedi-playbook
   cd slovo-propovedi-playbook
   ```

2. **Install the Galaxy roles:**

   ```bash
   just roles
   ```

3. **Create your configuration file:**

   ```bash
   mkdir -p inventory/host_vars/<your-host>
   cp examples/vars.yml inventory/host_vars/<your-host>/vars.yml
   ```

   Then open `inventory/host_vars/<your-host>/vars.yml` and fill in your domain names and secrets.

4. **Create your inventory file:**

   ```bash
   cp examples/hosts inventory/hosts
   ```

   Then edit `inventory/hosts` and add your server to the `[slovo_servers]` group.

5. **Run the playbook to set everything up and start the services:**

   ```bash
   just setup-all
   ```

6. **Create the admin user (run separately, after the services are up):**

   ```bash
   just ensure-admin-user
   ```

> [!NOTE]
> All commands above use `just` (see the `justfile` — run `just` to list the available recipes).
> If you don't have `just` installed, you can run the same steps with Ansible directly:
>
> ```bash
> ansible-galaxy install -r requirements.yml
> ansible-playbook -i inventory/hosts setup.yml --tags=setup-all,start
> ansible-playbook -i inventory/hosts setup.yml --tags=ensure-slovo-users-created
> ```

## Documentation

- [Configuring the playbook](docs/configuring-playbook.md)
- [Deploying the backend](docs/deploying-backend.md)
- [Deploying the frontend](docs/deploying-frontend.md)
- [Configuring Traefik](docs/configuring-traefik.md)

## License

AGPL-3.0
