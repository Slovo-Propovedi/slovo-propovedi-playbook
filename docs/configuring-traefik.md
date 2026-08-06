# Configuring Traefik

<sup>[Configuring the playbook](configuring-playbook.md) > Configuring Traefik</sup>

This document describes the Traefik reverse proxy that this playbook manages, and how to configure it.

## Overview

[Traefik](https://traefik.io/) is the reverse proxy used by this playbook. It sits in front of every service (backend, MinIO, Adminer) and handles:

- **TLS termination** — all traffic arrives over HTTPS.
- **Automatic Let's Encrypt certificates** — certificates are requested and renewed automatically.
- **Routing to backend services** — requests are routed by hostname to the correct container using Docker labels.

Traefik runs as its own Docker container (`slovo-traefik`) managed by the `slovo-traefik.service` systemd unit. It is installed by the `galaxy/traefik` role (based on [mother-of-all-self-hosting/ansible-role-traefik](https://github.com/mother-of-all-self-hosting/ansible-role-traefik)).

## How it works

1. Every Traefik-exposed service (backend, MinIO, Adminer) emits **Traefik Docker labels**. Each role renders its own labels file (from a `labels.j2` template) and the systemd unit passes it to the container via `--label-file`.
2. Traefik **discovers services on the shared Docker network** named `traefik` (see `slovo_playbook_reverse_proxy_container_network`).
3. Services join that shared network automatically via their `*_container_additional_networks_auto` variables in `group_vars/slovo_servers/main.yml`.

> [!IMPORTANT]
> For Traefik to reach a container, the `traefik.docker.network` label on that container must point to the **shared reverse-proxy network** (`traefik`) — the network Traefik itself is attached to — not the service's own primary network. The playbook wires this via `slovo_*_container_labels_traefik_docker_network` in `group_vars`. If this label is wrong, you get `502 Bad Gateway` from Traefik.

## Configuration

To enable the playbook-managed Traefik, set the reverse proxy type in your `vars.yml`:

```yaml
slovo_playbook_reverse_proxy_type: playbook-managed-traefik
```

Set a hostname for each service you enable:

```yaml
# Backend (NestJS API + docs)
slovo_backend_hostname: admin.example.com

# MinIO — the S3 API and the console are separate hostnames
slovo_minio_hostname: minio-api.example.com
slovo_minio_console_hostname: minio-console.example.com

# Adminer (optional)
slovo_adminer_hostname: adminer.example.com
```

Provide an email for Let's Encrypt certificate notifications (certificates are requested for each hostname automatically):

```yaml
traefik_config_certificatesResolvers_acme_email: admin@example.com
```

The full example is in [Configuring the playbook](configuring-playbook.md).

## DNS

Each hostname you configure above must have an A (IPv4) / AAAA (IPv6) record pointing to your server's IP. Because Traefik terminates TLS and routes by hostname, all records point to the **same server IP**:

- `admin.example.com` → server IP
- `minio-api.example.com` → server IP
- `minio-console.example.com` → server IP
- `adminer.example.com` → server IP (if Adminer is enabled)

## Ports

Traefik listens on:

- **Port 80 (HTTP)** — entrypoint `web`. Serves the Let's Encrypt HTTP challenge and redirects everything else to HTTPS.
- **Port 443 (HTTPS)** — entrypoint `web-secure`. All services are routed through this entrypoint.

Make sure your server's firewall allows inbound traffic on ports `80/tcp` and `443/tcp`.

## Timeouts

The playbook sets a **300-second read timeout** on both the `web` and `web-secure` entrypoints to accommodate large file uploads (sermon audio/video):

```yaml
# group_vars/slovo_servers/main.yml
traefik_config_entrypoint_web_transport_respondingTimeouts_readTimeout: 300s
traefik_config_entrypoint_web_secure_transport_respondingTimeouts_readTimeout: 300s
```

If you upload very large media files, these values may need to be increased further; adjust them in your `vars.yml` if necessary.

## MinIO routing

MinIO exposes **two Traefik routers**, each with its own hostname:

| Router | Label / name | Container port | Hostname variable |
| --- | --- | --- | --- |
| S3 API | `slovo-minio` | 9000 | `slovo_minio_hostname` |
| Console | `slovo-minio-console` | 9001 | `slovo_minio_console_hostname` |

The API router handles S3 requests (used by the backend and by clients uploading/downloading files). The console router serves the MinIO web UI (where you manage buckets and access keys).

## Disabling Traefik

To disable the playbook-managed Traefik, set:

```yaml
slovo_playbook_reverse_proxy_type: ''
```

When disabled:

- Traefik is not installed.
- Services do **not** emit Traefik labels (`slovo_*_container_labels_traefik_enabled` behavior is driven by `slovo_playbook_traefik_labels_enabled`, which follows `traefik_enabled`).
- Services do **not** join the `traefik` network (their `*_container_additional_networks_auto` lists become empty).

You would then need to expose service ports manually (e.g. publish container ports directly) and handle TLS yourself. **This is not recommended** — the playbook assumes Traefik is in front of everything, and no service publishes ports to the host by default.

## Troubleshooting

| Symptom | Likely cause | How to check / fix |
| --- | --- | --- |
| `502 Bad Gateway` | `traefik.docker.network` label mismatch | Ensure the service's `traefik.docker.network` label matches the shared network name (`traefik`). Check `docker network inspect traefik` to confirm both Traefik and the service container are attached. |
| Certificate not issued | Let's Encrypt email missing, or port 80 blocked | Set `traefik_config_certificatesResolvers_acme_email`, and confirm ports 80/443 are reachable from the internet (the HTTP challenge uses port 80). |
| Traefik logs | — | `journalctl -u slovo-traefik.service -f`. To raise log verbosity, set `traefik_config_log_level: DEBUG` and re-run the playbook. |
| Services not routed | Hostname record missing | Verify DNS records for each service hostname point to the server IP (see [DNS](#dns)). |
