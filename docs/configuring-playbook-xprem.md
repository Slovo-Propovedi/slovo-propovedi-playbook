# Configuring xprem (self-hosted Expo OTA updates)

The playbook runs [xprem](https://github.com/mercuretechnologies/xprem) as the OTA (over-the-air) update server for the slovo-propovedi mobile app. xprem speaks the [Expo Updates protocol v1](https://docs.expo.dev/technical-specs/expo-updates-1/), so an app built with `expo-updates` receives JS bundle updates from your own server instead of EAS Update. The project was formerly named `expo-open-ota`.

The role lives in `roles/custom/slovo-xprem/` and is wired into `setup.yml` and `group_vars/slovo_servers/main.yml`.

## What gets deployed

| Piece | Value |
| --- | --- |
| Image | `ghcr.io/mercuretechnologies/xprem:v3.2.6` (pinned; Renovate tracks new tags) |
| Mode | Control plane (`DB_URL` set): apps, branches, channels and signing keys live in PostgreSQL |
| Storage | Local filesystem — `/slovo/xprem/data` on the host, `/data` in the container |
| Cache | In-process (`CACHE_MODE=local`, no Redis) |
| Listener | Port 3000 — dashboard at `/dashboard`, health at `/hc`, device protocol at `/manifest` and `/assets` |
| Networks | `slovo-xprem` (primary) + `traefik` + `slovo-postgres` |
| Memory cap | 256 MB |
| systemd unit | `slovo-xprem.service`, service-manager priority 700 (after MinIO 600) |

The OTA server needs both the shared Traefik network (to be reachable from the internet) and the `slovo-postgres` network (to reach the database by name). Both joins are wired automatically in `group_vars/slovo_servers/main.yml` via `slovo_xprem_container_additional_networks_auto`.

### Database

The `xprem` database and role are provisioned declaratively by the postgres role through `postgres_managed_databases_additional` (see `group_vars`), which references `slovo_xprem_postgres_db` and `slovo_xprem_postgres_user` — both defined in host vars, like `slovo_backend_postgres_db` / `slovo_backend_postgres_user`. Because `postgres_backup_databases_auto` is derived from `postgres_managed_databases`, the xprem database is included in the daily `pg_dump` rotation with no extra configuration. The database schema is created and migrated by xprem itself on boot (look for `⚙️  [CONTROL] Initializing Control Plane (DB Mode)..` in the logs).

> [!NOTE]
> **Legacy clusters and the locale workaround.** The vendored postgres role creates a managed database with `CREATE DATABASE ... LC_CTYPE ... LC_COLLATE ...` but no `TEMPLATE template0`. PostgreSQL refuses a locale that differs from the collation of template1. This VPS's cluster was initialized before the `ru_RU.UTF-8` override in `group_vars` (template1 is `C`), so the role's own `CREATE DATABASE` fails with `new collation (ru_RU.UTF-8) is incompatible with the collation of the template database (C)`. The role runs psql with `ON_ERROR_STOP=0` and only fails on lines matching `^ERROR:`, while psql prefixes errors from a `--file` run with `psql:<file>:<line>: ERROR:` — so the failure is swallowed and the task still reports `changed` even though the database was not created.
>
> To close this gap, the `postgres_managed_databases_additional` entry carries an idempotent `additional_sql_queries` statement that creates the database `WITH TEMPLATE template0` (the only template that permits a different locale). It is a no-op once the database exists, and also a no-op on fresh clusters whose template1 already has the configured locale, so `setup-postgres` remains safe to re-run.

### Storage and delivery

With `STORAGE_MODE=local` the server writes published bundles and assets to the bind-mounted `/data` directory and serves them itself. There is no CDN: device downloads traverse Traefik and this VPS, so OTA traffic counts against the server's bandwidth and the 256 MB memory cap.

## Prerequisites

1. **DNS**: an `A` record `ota.slovo-propovedi.ru → <VPS IP>` must exist before the first apply, so Traefik can obtain the Let's Encrypt certificate.
2. **Four vault secrets** (see below) in `inventory/host_vars/slovo-propovedi.ru/vars.yml`.
3. **Non-secret host vars**:

```yaml
# xprem (self-hosted Expo OTA update server)
slovo_xprem_enabled: true
slovo_xprem_hostname: ota.slovo-propovedi.ru
# Placeholder — change it to a mailbox you actually monitor.
slovo_xprem_admin_email: admin@slovo-propovedi.ru
# PostgreSQL database/role owned by xprem (provisioned by the postgres role).
slovo_xprem_postgres_db: xprem
slovo_xprem_postgres_user: xprem
```

`slovo_xprem_hostname` is also the server's `BASE_URL`, and therefore the `updates.url` baked into the mobile app. Changing it later requires a new native build of the app.

## Required vault secrets

The role does not ship default values for these: an undefined secret aborts the apply with an error naming the missing variable (deliberate fail-fast, not a broken deploy).

| Variable | Purpose | Generate with |
| --- | --- | --- |
| `secret_slovo_xprem_postgres_password` | Password of the `xprem` PostgreSQL role and of the `DB_URL` DSN | `openssl rand -hex 32` |
| `secret_slovo_xprem_db_keys_master_key` | `DB_KEYS_MASTER_KEY_B64` — master key that seals per-app Expo signing keys in PostgreSQL | `openssl rand -base64 32` |
| `secret_slovo_xprem_jwt_secret` | `JWT_SECRET` — dashboard/API token signing secret | `openssl rand -base64 32` |
| `secret_slovo_xprem_admin_password` | `ADMIN_PASSWORD` — password of the first dashboard admin | policy-compliant password, e.g. `printf '%s!Aa1' "$(openssl rand -hex 12)"` |

Use a hex password for the database: it lands inside a `postgres://` URL, and `/` or `+` from base64 output would need percent-encoding in the DSN.

`ADMIN_PASSWORD` is not a URL component, but xprem enforces its password policy when seeding the first admin: at least 8 characters with an uppercase letter, a lowercase letter, a digit and a special character. A non-compliant value does not fail the playbook — the container crash-loops in the seed-admin migration — so generate it with the policy in mind (the command above guarantees all four classes).

Encrypt each value and paste the result into the secrets section at the bottom of `inventory/host_vars/slovo-propovedi.ru/vars.yml`:

```sh
ansible-vault encrypt_string --name 'secret_slovo_xprem_postgres_password' "$(openssl rand -hex 32)"
ansible-vault encrypt_string --name 'secret_slovo_xprem_db_keys_master_key' "$(openssl rand -base64 32)"
ansible-vault encrypt_string --name 'secret_slovo_xprem_jwt_secret' "$(openssl rand -base64 32)"
ansible-vault encrypt_string --name 'secret_slovo_xprem_admin_password' "$(printf '%s!Aa1' "$(openssl rand -hex 12)")"
```

The command prints a `!vault |` block; paste it under the secrets header next to the existing `secret_slovo_*` entries.

> [!WARNING]
> **Do not regenerate these secrets after the first boot.**
>
> - Changing `DB_KEYS_MASTER_KEY_B64` makes the per-app signing keys already sealed in PostgreSQL unreadable — xprem can no longer sign manifests for those apps.
> - Changing the database password requires the same value in the PostgreSQL role; otherwise xprem cannot connect.
> - Changing `JWT_SECRET` invalidates existing dashboard sessions (recoverable — log in again).
> - `ADMIN_PASSWORD` is only read on the very first boot to seed the admin account; afterwards the password lives in PostgreSQL and the variable is ignored.

## Variables reference

Most values are wired in `group_vars/slovo_servers/main.yml`; override them only if you know what consumes them.

| Variable | Default | Description |
| --- | --- | --- |
| `slovo_xprem_enabled` | `true` | Install (or uninstall, when `false`) the service |
| `slovo_xprem_identifier` | `slovo-xprem` | Container and systemd unit name |
| `slovo_xprem_version` | `v3.2.6` | Pinned image tag |
| `slovo_xprem_hostname` | `''` | Public hostname; also `BASE_URL` / app `updates.url` |
| `slovo_xprem_path_prefix` | `/` | Traefik path prefix (leave at `/`; see limitations) |
| `slovo_xprem_base_path` | `/slovo/xprem` | Config dir (`env`, `labels`) |
| `slovo_xprem_data_path` | `/slovo/xprem/data` | Local update storage, mounted at `/data` |
| `slovo_xprem_container_image` | `ghcr.io/mercuretechnologies/xprem:{{ version }}` | Image reference |
| `slovo_xprem_container_image_name_prefix` | `""` | Registry prefix for mirrors |
| `slovo_xprem_container_network` | `slovo-xprem` | Primary Docker network (auto-created) |
| `slovo_xprem_container_additional_networks` | `default + auto + custom` | Joined networks |
| `slovo_xprem_container_labels_traefik_enabled` | `{{ slovo_playbook_traefik_labels_enabled }}` | Emit Traefik labels |
| `slovo_xprem_container_labels_traefik_hostname` | `{{ slovo_xprem_hostname }}` | Traefik `Host()` rule |
| `slovo_xprem_container_labels_traefik_entrypoints` | `web-secure` | Traefik entrypoint (HTTPS) |
| `slovo_xprem_container_labels_traefik_tls` | `true` | Enable TLS on the router |
| `slovo_xprem_container_labels_traefik_tls_certResolver` | `default` | Let's Encrypt resolver |
| `slovo_xprem_container_extra_arguments` | `["--memory=256m"]` | Extra `docker create` args |
| `slovo_xprem_systemd_required_services_list` | `default + auto + custom` | Units required before start (`docker`, `slovo-postgres`) |
| `slovo_xprem_admin_email` | `''` | First admin login (email) |
| `slovo_xprem_postgres_db` | `''` (required, host vars) | Database provisioned by the postgres role and used in the `DB_URL` DSN |
| `slovo_xprem_postgres_user` | `''` (required, host vars) | Owner role of that database (`DB_URL` user) |
| `slovo_xprem_uninstall_remove_data` | `false` | Also delete `/slovo/xprem` on uninstall |

The env file rendered at `/slovo/xprem/env` (mode `0640`) contains the exact upstream variable set:

```
BASE_URL=https://<hostname>
DB_URL=postgres://xprem:<password>@slovo-postgres:5432/xprem?sslmode=disable
DB_KEYS_MASTER_KEY_B64=<master key>
JWT_SECRET=<jwt secret>
STORAGE_MODE=local
LOCAL_BUCKET_BASE_PATH=/data
CACHE_MODE=local
USE_DASHBOARD=true
ADMIN_EMAIL=<admin email>
ADMIN_PASSWORD=<admin password>
```

If the first apply logs `unknown environment variable` warnings, compare this list with the docs shipped for the pinned image tag and adjust `roles/custom/slovo-xprem/templates/env.j2`. The env file changes trigger a service restart on the next run.

## First apply

The `xprem` database and role are created by the postgres role's managed-databases tasks, which run **only under the postgres tags** (`setup-postgres` / `install-postgres`, or the umbrella `setup-all` / `install-all`). The xprem tag alone does not provision them.

Full deployment, recommended on a fresh host (also installs Docker, PostgreSQL, Traefik and the other services):

```bash
# From the playbook repo root
just setup-all --ask-vault-pass
```

Minimal correct sequence on a host where Docker and PostgreSQL are already deployed and you are only adding xprem:

```bash
ansible-playbook -i inventory/hosts setup.yml \
  --tags=setup-postgres,setup-slovo-xprem,start --ask-vault-pass
```

Both extra tags matter: without `setup-postgres` the managed-databases tasks are skipped, and `start` is what makes the systemd service manager enable and start the unit.

Verified on this VPS (2026-10-24): the sequence above provisions the database, renders the env file and starts the unit. To provision only the database (for example to unblock an already-deployed unit), `--tags=setup-postgres` is sufficient — it is idempotent and never touches an existing database. Restart the unit afterwards with `systemctl restart slovo-xprem.service` (or include the `start` tag).

> [!NOTE]
> **One-time bootstrap already performed on this host (2026-10-24).** Before the `TEMPLATE template0` workaround was added, the postgres role had created the `xprem` role and its password but not the database, because of the locale/template1 mismatch described under [Database](#database). The database was created once by hand with `TEMPLATE template0`; every later `setup-postgres` run is idempotent. Hosts provisioned with the current playbook need no manual step.

> [!WARNING]
> `just setup-slovo-xprem --ask-vault-pass` expands to `--tags=setup-slovo-xprem,start` and **never creates the database**. On a first apply the unit starts against a nonexistent database and enters a restart loop; `journalctl -u slovo-xprem.service` shows `FATAL: database "xprem" does not exist (SQLSTATE 3D000)`. Use it only after the database already exists (created by an earlier `setup-all`/`setup-postgres` run).

The role fails before touching the host if `slovo_xprem_identifier`, `slovo_xprem_base_path`, `slovo_xprem_version`, `slovo_xprem_admin_email`, `slovo_xprem_postgres_db`, `slovo_xprem_postgres_user` or (with Traefik labels on) `slovo_xprem_hostname` is empty, and fails at template time if a `secret_slovo_xprem_*` variable is undefined.

## Post-apply verification

```bash
# Unit is running (priority 700, after slovo-postgres)
systemctl status slovo-xprem

# Logs: the container runs with --log-driver=none, so its output goes to the
# journal via `docker start --attach`. `docker logs slovo-xprem` is EMPTY.
journalctl -u slovo-xprem.service -n 100 --no-pager

# Health endpoint
curl -fsS https://ota.slovo-propovedi.ru/hc

# Dashboard (HTTP 200 for the login page)
curl -fsSI https://ota.slovo-propovedi.ru/dashboard | head -n 1
```

Expect `⚙️  [CONTROL] Initializing Control Plane (DB Mode)..` and a successful migration run in the journal on first boot.

### Protocol smoke test

The device protocol endpoint is `https://<hostname>/manifest` (the app's `updates.url` is the bare host; `expo-updates` appends `/manifest`). A control-plane server resolves the app from the `expo-app-id` header, so include it:

```bash
curl -i https://ota.slovo-propovedi.ru/manifest \
  -H 'expo-protocol-version: 1' \
  -H 'expo-platform: android' \
  -H 'expo-runtime-version: <runtime version from app config>' \
  -H 'expo-app-id: <app UUID from the dashboard>' \
  -H 'expo-channel-name: production'
```

- `expo-runtime-version` must match the app's `runtimeVersion` exactly, otherwise xprem answers "no update available".
- Before the first publish (or before a channel is attached to a branch) the correct answer is the protocol's no-update response, not a manifest.
- A `401`/error body usually means a wrong or missing `expo-app-id`; a `502` from Traefik means the container is down (check the journal).

## Dashboard bootstrap

Open `https://ota.slovo-propovedi.ru/dashboard` and sign in with `slovo_xprem_admin_email` / `secret_slovo_xprem_admin_password`.

> [!NOTE]
> The vault credentials are the live ones only when the **first successful boot** seeded the admin from this env. The seed is one-time: if the container crash-looped with an earlier `ADMIN_PASSWORD` (e.g. a non-compliant one), PostgreSQL may hold a different value. Verify with the probe in [Troubleshooting](#troubleshooting) before rotating anything.

1. **Create the app**: apps → create → name `slovo-propovedi-mobile`. Open **App Info** and copy the **App ID** (UUID). It becomes the `expo-app-id` header and `npx eoas init` project id.
2. **Code signing certificate**: either
   - download the dashboard-generated pair's certificate — **App Info → Download certificate** — and save it as `certs/certificate.pem` in the mobile repo (the private key stays sealed in PostgreSQL, encrypted with `DB_KEYS_MASTER_KEY_B64`); or
   - generate your own pair locally with `npx eoas generate-certs` (it writes `certs/certificate.pem` and `certs/private-key.pem`), commit only the certificate, keep `private-key.pem` off the repo, and import the pair into the app when creating it. The exact import wording in the dashboard can differ between releases — follow the live xprem docs if the UI does not match.

   The certificate is embedded in the native binary; changing it requires a new native build, and every manifest is signed with the matching private key.
3. **Publish the first update / create the branch**: from the mobile repo, publish to `production` (see CI below) or create the branch in the dashboard.
4. **Create the channel**: **Channels → Create Channel**, name it `production`, attach it to the `production` branch. A fresh channel serves exactly that branch.
5. **Create an API token for CI**: **API tokens → create**, copy it immediately (it is shown once). xprem tokens are app-scoped and are used as `EOO_TOKEN` by the publish CLI.
6. **`npx eoas init`** in the mobile repo: app UUID, server URL `https://ota.slovo-propovedi.ru`, and "yes, I already have certificates". It adds `expo-channel-name`, `expo-app-id` and `xprem-branch` to `updates.requestHeaders`.
7. **Rebuild the native app**: `updates.url`, the channel and the certificate are baked in at build time. Existing binaries keep pointing at the old server.

## Publish from CI (Forgejo)

Store the dashboard API token as the repository/org secret **`XPREM_EOO_TOKEN`** (Forgejo → Settings → Actions → Secrets). The publish step:

```yaml
- name: Publish OTA update
  env:
    EOO_TOKEN: ${{ secrets.XPREM_EOO_TOKEN }}
    RELEASE_CHANNEL: production
  run: npx eoas publish --branch production --nonInteractive
```

- `--branch` is the only thing that selects the update branch; `RELEASE_CHANNEL` only drives `expo export`.
- `--nonInteractive` aborts on a dirty git tree (untracked files count) — commit everything first, or pass `--disableRepositoryCheck` deliberately.
- Without `EOO_TOKEN`, eoas silently falls back to Expo authentication and the xprem server rejects the publish.
- The runtime version of the export must match the installed binary, or the update is silently not delivered.

## Server-side key registration

In control-plane mode the signing keys are **sealed in PostgreSQL**, and the only key material this playbook provides is the environment variable `DB_KEYS_MASTER_KEY_B64` (rendered from `secret_slovo_xprem_db_keys_master_key`). The Helm chart's `keysStorageType` (env / local key files / AWS Secrets Manager) applies to the stateless, single-app mode only and is ignored here. Consequence: the PostgreSQL dump plus the master key are both required to recover a server that can still sign updates; a dump restored without the original master key loses the app keys.

## Backups

The `xprem` database is part of the daily pg_dump rotation automatically (see [Configuring backups](configuring-backups.md)). The local bundle/asset storage at `/slovo/xprem/data` is **not** mirrored by the NAS backup role, which pulls only the postgres dumps and MinIO data. Bundles are reproducible from the mobile repo via `eoas publish`; the database (metadata, channels, tokens, sealed keys) is the irreplaceable part. Keep `secret_slovo_xprem_db_keys_master_key` in the vault — without it the restored database cannot sign updates.

## Troubleshooting

| Symptom | Likely cause | How to check / fix |
| --- | --- | --- |
| Traefik returns 502 | xprem is not running, or the `traefik.docker.network` label points at the wrong network | `journalctl -u slovo-xprem.service -n 100`; the label must name the shared Traefik network (`traefik`), which is what `group_vars` wires |
| Container restart loop, `JWT_SECRET not set` or `Neither AWSSM_DB_KEYS_MASTER_KEY_SECRET_ID nor DB_KEYS_MASTER_KEY_B64 is set` | A `secret_slovo_xprem_*` variable is undefined (the env file rendered empty) | Check the vault vars and re-run `just setup-slovo-xprem --ask-vault-pass` |
| `Invalid BASE_URL` in the journal | `slovo_xprem_hostname` is empty while Traefik labels are disabled | Set the hostname — `BASE_URL` is always built from it |
| Database connection errors (`FATAL: database ... does not exist`) | The `xprem` database was never provisioned: the postgres tags did not run, or the role's `CREATE DATABASE` failed silently on a legacy cluster (locale/template1 mismatch) | Check `SELECT datname FROM pg_database`; run `just setup-all --ask-vault-pass` or add `setup-postgres` to the tags (see [First apply](#first-apply)), then restart `slovo-xprem`. The `TEMPLATE template0` bootstrap in `group_vars` covers the legacy-cluster case |
| Database SSL negotiation failure | PostgreSQL in this stack serves no TLS; the role already pins `?sslmode=disable` in `DB_URL` | Verify the rendered `/slovo/xprem/env` still carries `?sslmode=disable`; if it does not, re-run a setup that includes `setup-slovo-xprem` so the env file is re-rendered |
| Journal shows `unknown environment variable` warnings | The pinned image renamed or dropped a variable | Compare the rendered env file with the docs for that tag and adjust `env.j2` |
| `docker logs slovo-xprem` prints nothing | Expected: the unit uses `--log-driver=none` | Use `journalctl -u slovo-xprem.service` (container output is attached to the unit) |
| Dashboard login rejected (`401 Invalid email or password`) | The live password is the one seeded on the first successful boot, which may differ from the current vault value | Verify with the form-encoded probe below; `200` means the saved client-side value is stale, `401` means PostgreSQL holds an older seed value (reset = DB intervention) |
| Manifest returns no update | Branch/channel mismatch or wrong runtime version | Check that a channel named `production` points at the `production` branch and that `expo-runtime-version` matches the build |

### Checking which dashboard password is live

The dashboard form posts `application/x-www-form-urlencoded` (a JSON body answers `400 Email is empty`). Probe from the server so the secret never enters local shell history and is never printed:

```bash
ADMIN_EMAIL=$(grep -m1 '^ADMIN_EMAIL=' /slovo/xprem/env | cut -d= -f2-)
ADMIN_PASSWORD=$(grep -m1 '^ADMIN_PASSWORD=' /slovo/xprem/env | cut -d= -f2-)
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://ota.slovo-propovedi.ru/auth/login \
  --data-urlencode "email=$ADMIN_EMAIL" --data-urlencode "password=$ADMIN_PASSWORD"
```

- `200` — the env/vault value is the live password; a `401` in the browser means the client (browser or password manager) has a stale value.
- `401` — PostgreSQL holds the value from the first successful seed, which differs from the current vault. `ADMIN_PASSWORD` is not re-synced on boot, so aligning them is a DB intervention.

## Limitations

- The role exposes xprem at `/`; `slovo_xprem_path_prefix` only affects the Traefik rule and is not propagated into `BASE_URL`. Leave it at `/`.
- Traffic is served directly by the server (no CDN), capped at 256 MB of memory.
- `TRUST_PROXY_HEADERS` is not set, so xprem sees the Traefik container's IP. API-token IP allowlists would therefore allow/deny the proxy, not the real client.
- Dashboard font assets (e.g. `/dashboard/assets/inter-latin-wght-normal-*.woff2`) are answered with the SPA fallback (`text/html`, starts with `<!doctype html>`) even though the files exist in the image and are valid WOFF2. The browser logs `invalid sfntVersion` and falls back to a system font — cosmetic upstream serving bug, not a broken deploy.
- Uninstalling (`slovo_xprem_enabled: false`) stops and removes the unit and container, and deletes `/slovo/xprem` only when `slovo_xprem_uninstall_remove_data: true`. The `xprem` database and role are left untouched in PostgreSQL on purpose — data safety, since the sealed signing keys are unrecoverable without a dump — and the `slovo-xprem` Docker network also stays, matching the other roles. Drop the database/role manually through `psql` if it is truly no longer needed.
