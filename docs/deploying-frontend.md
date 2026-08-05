# Deploying the frontend

<sup>[Configuring the playbook](configuring-playbook.md) > Deploying the frontend</sup>

This document describes how the slovo-propovedi-admin **frontend** is built and deployed by the playbook, and the things you should know when operating it.

## Overview

The frontend is a **Svelte 5** single-page application (built with Vite) that provides the admin panel web UI. It is served by **nginx** inside a Docker container, **self-built from source** rather than pulled from a registry.

- Repository: `https://git.lightnode.ru/Slovo_Propovedi/slovo-propovedi-admin.git`
- Branch: `master`
- Image name: `slovo-frontend:latest`
- Served on container port `8080` (exposed to the outside world only through Traefik)

The relevant playbook variables:

| Variable | Default |
| --- | --- |
| `slovo_frontend_container_image_self_build` | `true` |
| `slovo_frontend_container_image_self_build_repo` | `https://git.lightnode.ru/Slovo_Propovedi/slovo-propovedi-admin.git` |
| `slovo_frontend_container_image_self_build_repo_version` | `master` |
| `slovo_frontend_container_src_path` | `{{ slovo_frontend_base_path }}/container-src` (i.e. `/slovo/frontend/container-src`) |
| `slovo_frontend_container_image` | `slovo-frontend:latest` |
| `slovo_frontend_container_port` | `8080` |
| `slovo_frontend_backend_upstream` | `slovo-backend:3000` |
| `slovo_frontend_hostname` | *(empty — must be set)* |

## The nginx reverse proxy

The SPA calls the API through the **relative `/api` path** (`fetch('/api/...')`), so all API traffic from the browser is served from the same hostname as the UI. The nginx inside the frontend container handles this: a `location /api/` block **strips the `/api` prefix** and proxies the request to the backend container on the shared Docker network:

```nginx
location /api/ {
    proxy_pass http://{{ slovo_frontend_backend_upstream }}/;
    ...
}
```

The upstream (`slovo_frontend_backend_upstream`, default `slovo-backend:3000`) is the backend container name and port. Because nginx strips the `/api/` prefix, the backend receives plain `/sermons`, `/playlists`, etc. requests — the same requests it would receive if the browser talked to it directly.

## Runtime-templated nginx.conf

The frontend's Docker image has an nginx.conf **baked in** (`frontend/web-app/nginx.conf` in the repository). That version proxies `/api/` to `backend:3000` — the **docker-compose service name**, which does **not exist** in the playbook deployment (the backend container is named `slovo-backend`).

The playbook therefore **templates its own nginx.conf at runtime** (exactly like it templates the backend's env file) and **mounts it into the container, overriding the baked-in one**:

- Template: `roles/custom/slovo-frontend/templates/nginx.conf.j2`
- Rendered to: `{{ slovo_frontend_base_path }}/nginx.conf` (`/slovo/frontend/nginx.conf`)
- Mounted into the container at `/etc/nginx/conf.d/default.conf:ro` via the systemd unit

The only difference from the baked-in config is the `proxy_pass` target, which uses `slovo_frontend_backend_upstream` instead of the hardcoded `backend:3000`. All security headers, caching rules, and the SPA fallback (`try_files $uri $uri/ /index.html`) are identical.

> [!NOTE]
> Do **not** edit the repository's `frontend/web-app/nginx.conf` for playbook deployments — that file is used by the docker-compose workflow. Playbook deployments get their config from the playbook's `nginx.conf.j2` template. To change the reverse-proxy behavior in a playbook deployment, edit the template and re-run the playbook.

## Network connectivity

The frontend container's primary network is `slovo-frontend`. It additionally joins two networks, wired in `slovo_frontend_container_additional_networks_auto` in `group_vars/slovo_servers/main.yml`:

| Network | Why |
| --- | --- |
| `traefik` | So Traefik can route traffic to the container (shared reverse-proxy network) |
| `slovo-backend` | So the frontend's nginx can reach the backend container at `slovo-backend:3000` for `/api/` requests |

> [!IMPORTANT]
> The frontend can only proxy to `slovo-backend:3000` because it is attached to the **`slovo-backend` network**. If that join is missing, `/api/` requests from the SPA fail with `502 Bad Gateway` from the frontend's nginx. Verify connectivity with `docker network inspect slovo-backend` — the `slovo-frontend` container must be listed.

## Self-build process

During installation (the `setup-slovo-frontend` / `setup-all` tags), the playbook:

1. Ensures the repository directory (`{{ slovo_frontend_container_src_path }}`) is owned by the `slovo` user.
2. Clones (or updates) the repository via `ansible.builtin.git`:
   ```sh
   git clone https://git.lightnode.ru/Slovo_Propovedi/slovo-propovedi-admin.git <src_path>
   ```
   on the `master` branch (`force: yes`, so a rerun always matches the remote).
3. Builds the image with Docker Buildx, using the shared constrained builder (`--builder=slovo-constrained`, see [Build resource limits](#build-resource-limits)). `--load` exports the built image to the local Docker store:
   ```sh
   docker buildx build \
     --builder=slovo-constrained \
     --load \
     --tag=slovo-frontend:latest \
     --file=<src_path>/frontend/web-app/Dockerfile \
     <src_path>/frontend/web-app
   ```
   The `frontend/web-app/Dockerfile` is used and `frontend/web-app/` is the build context.

The image is rebuilt whenever the git checkout changes or the `setup-all` tags are re-run, so updating the frontend is as simple as re-running the playbook:

```sh
ansible-playbook -i inventory/hosts setup.yml --tags=setup-all,start
```

> [!NOTE]
> Unlike the backend, the frontend repository is cloned over **HTTPS** (no SSH key is needed for `git.lightnode.ru`).

### Build resource limits

Frontend builds run in the single shared, **resource-constrained buildx builder** (the `docker-container` driver), created by the `slovo-buildx` role. The builder's container has a kernel-enforced memory and CPU ceiling that bounds the *entire* build — the BuildKit daemon plus every parallel `RUN` step.

| Setting | Variable | Default |
| --- | --- | --- |
| Builder memory ceiling | `slovo_buildx_builder_memory` | `1g` |
| Builder CPU quota (µs/period) | `slovo_buildx_builder_cpu_quota` | `80000` (= 0.8 CPU / ~80%) |

> [!NOTE]
> The previous per-build `--memory`/`--cpus` flags were removed: `--cpus` was never a valid `docker buildx build` flag (it is `docker run`-only), and `--memory` only limited each build step in isolation, not the build as a whole.

The frontend build is light (a Vite bundle), so the shared 1g ceiling is ample. The Node.js heap is additionally capped via `NODE_OPTIONS=--max-old-space-size=384` in the Dockerfile; keep it below `slovo_buildx_builder_memory` so V8 gives first, with the builder as the backstop.

If a build ever runs out of memory (the *build* fails — the desired safety behavior; the server stays up), raise the ceiling in `vars.yml`:
```yaml
slovo_buildx_builder_memory: "1500m"
```
then recreate the builder and re-run (the buildx role must run together with the service — `setup-service` alone skips it):
```sh
docker buildx rm slovo-constrained
just run --tags=setup-slovo-buildx,setup-slovo-frontend,start
```

## Container security

The frontend container runs with:

- `--user={{ slovo_user_uid }}:{{ slovo_user_gid }}` — runs as the `slovo` user's auto-assigned uid/gid (the owner of the rendered config files), never as root.
- `--cap-drop=ALL` — no Linux capabilities.
- **No `--read-only`** — deliberately. nginx needs a writable filesystem for its temp/cache files, so the frontend container's root filesystem is left writable (unlike the backend container, which is read-only). The nginx config file itself is mounted `:ro` so the running container cannot modify it.

The nginx server inside the image is configured to listen on port **8080** (not 80), so no special capabilities are needed to bind it as a non-root user.

## Traefik routing

The frontend is exposed through Traefik on the hostname set in `slovo_frontend_hostname` (e.g. `admin-app.example.com`):

| Hostname | Playbook variable | Container port |
| --- | --- | --- |
| `admin-app.example.com` | `slovo_frontend_hostname` | 8080 |

Traefik routes `https://admin-app.example.com/...` to the `slovo-frontend` container on port 8080. The browser loads the SPA from this hostname, and all `/api/...` calls from the SPA go to the same hostname — nginx then proxies them to the backend container (`slovo-backend:3000`) over the shared Docker network, as described above.

## Troubleshooting

| Symptom | Likely cause | How to check / fix |
| --- | --- | --- |
| SPA loads but API calls fail with `502 Bad Gateway` | Frontend is not on the `slovo-backend` network | `docker network inspect slovo-backend` — the `slovo-frontend` container must be listed. The join comes from `slovo_frontend_container_additional_networks_auto` in `group_vars`. |
| `/api/` requests still go to `backend:3000` (docker-compose name) | Old/baked-in nginx.conf in use | Confirm the rendered config is mounted: `docker exec slovo-frontend cat /etc/nginx/conf.d/default.conf` — the `proxy_pass` must show `slovo-backend:3000`. Re-run the playbook so the templated `nginx.conf` is installed and the container restarts. |
| `slovo-frontend.service` fails to start | `slovo_frontend_hostname` empty | The role fails validation when Traefik is enabled but no hostname is set. Set `slovo_frontend_hostname` in `vars.yml`. |
