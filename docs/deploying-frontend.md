# Deploying the frontend

<sup>[Configuring the playbook](configuring-playbook.md) > Deploying the frontend</sup>

> [!NOTE]
> The frontend now deploys via **Forgejo Actions**: pushing a `v*` tag triggers `.forgejo/workflows/release.yml` in the `slovo-propovedi-admin` repository, which runs `scripts/vps-deploy.sh` on the server. The Ansible `slovo-frontend` role is **retired** from the playbook run list (it no longer appears in `setup.yml`); the instructions below are kept for historical reference only.

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
| `slovo_frontend_hostname` | *(empty — must be set)* |
| `slovo_backend_api_hostname` | *(empty — must be set; the SPA calls the API directly at this hostname)* |

## nginx configuration

The SPA is a static bundle served by nginx, and it calls the API **directly** at `https://{{ slovo_backend_api_hostname }}` (in the production deployment: `https://api.slovo-propovedi.ru`). All API traffic goes straight from the browser to that hostname over HTTPS — nginx does not forward any requests to the backend.

Because those API calls are **cross-origin**, nginx must tell the browser to allow them. The `Content-Security-Policy` header set by the config includes the API origin in `connect-src`:

```nginx
add_header Content-Security-Policy "default-src 'self'; img-src 'self' data: https:; script-src 'self'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src 'self' https://fonts.googleapis.com https://fonts.gstatic.com; connect-src 'self' https://{{ slovo_backend_api_hostname }}; media-src 'self' https:;" always;
```

The rest of the server block is plain static serving: `root /usr/share/nginx/html`, long-term caching for `/assets/` (`expires 1y`), and the SPA fallback (`try_files $uri $uri/ /index.html`).

## Runtime-templated nginx.conf

The frontend's Docker image ships with an nginx.conf **baked in** (`frontend/web-app/nginx.conf` in the repository). Because the API hostname (`slovo_backend_api_hostname`) is a deployment-specific value that must end up in the CSP `connect-src` header, the playbook **templates its own nginx.conf at runtime** (exactly like it templates the backend's env file) and **mounts it into the container, overriding the baked-in one**:

- Template: `roles/custom/slovo-frontend/templates/nginx.conf.j2`
- Rendered to: `{{ slovo_frontend_base_path }}/nginx.conf` (`/slovo/frontend/nginx.conf`)
- Mounted into the container at `/etc/nginx/conf.d/default.conf:ro` via the systemd unit

The templated config serves the static SPA, sets the security headers (including the CSP `connect-src` entry for `https://{{ slovo_backend_api_hostname }}`), and enables long-term caching for `/assets/`.

> [!NOTE]
> Do **not** edit the repository's `frontend/web-app/nginx.conf` for playbook deployments — that file is used by the docker-compose workflow. Playbook deployments get their config from the playbook's `nginx.conf.j2` template. To change the nginx configuration (security headers, caching, CSP) in a playbook deployment, edit the template and re-run the playbook.

## Network connectivity

The frontend container's primary network is `slovo-frontend`. It additionally joins **one** network, wired in `slovo_frontend_container_additional_networks_auto` in `group_vars/slovo_servers/main.yml`:

| Network | Why |
| --- | --- |
| `traefik` | So Traefik can route traffic to the container (shared reverse-proxy network) |

The frontend does **not** join the `slovo-backend` network: the SPA calls the API directly over HTTPS from the browser, so the nginx container never needs to reach the backend container itself.

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

Traefik routes `https://admin-app.example.com/...` to the `slovo-frontend` container on port 8080. The browser loads the SPA from this hostname; the SPA then calls the API **directly** at `https://{{ slovo_backend_api_hostname }}` (a different hostname), which the nginx CSP `connect-src` header allows.

## Troubleshooting

| Symptom | Likely cause | How to check / fix |
| --- | --- | --- |
| SPA loads but API calls fail | `slovo_backend_api_hostname` doesn't match the API the SPA is actually calling | Check the rendered config: `docker exec slovo-frontend cat /etc/nginx/conf.d/default.conf` — the CSP `connect-src` must include the exact API origin (`https://{{ slovo_backend_api_hostname }}`). Set the variable in `vars.yml` and re-run the playbook. |
| API calls blocked by the browser (CSP "Refused to connect") | CSP `connect-src` doesn't include the API origin | Same as above — the CSP is templated from `slovo_backend_api_hostname`, so a blocked request means the variable is empty or wrong for the API the SPA calls. |
| API calls rejected by the backend | The backend application doesn't allow the frontend origin (CORS) | Check the backend logs for CORS errors. Because the SPA calls the API cross-origin, the backend application must allow the frontend origin (`https://{{ slovo_frontend_hostname }}`). |
| `slovo-frontend.service` fails to start | `slovo_frontend_hostname` or `slovo_backend_api_hostname` empty | The role fails validation: the Traefik hostname is required when Traefik is enabled, and `slovo_backend_api_hostname` is required whenever the frontend is enabled (the SPA calls the API directly at it). Set both in `vars.yml`. |
