# Configuring backups

This playbook provides automated backups of the slovo-propovedi infrastructure. PostgreSQL dumps run daily on the VPS, and an optional NAS-side role pulls the dumps and MinIO data over SSH.

## Architecture

```
┌────────── VPS (slovo.example.com) ──────────┐
│  slovo-postgres  ──pg_dump──>  postgres-backup │  daily 04:30 UTC
│  slovo-minio     (data on disk)               │
└───────────────────────────────────────────────┘
                     │  SSH (rrsync, read-only keys)
                     ▼
┌────────── NAS (nas.example.com) ───────────┐
│  /mnt/data/backups/slovo-postgres  ← rsync   │  daily 06:00 UTC
│  /mnt/data/backups/slovo-minio     ← rsync   │
└──────────────────────────────────────────────┘
```

- **Pull model**: the NAS initiates the connection (no inbound ports needed on the VPS).
- **Per-module scoping**: each SSH key can only read one source directory (rrsync-enforced).
- **Not atomic**: an in-progress upload on the VPS may produce a partial object sync. MinIO objects are UUID-named and immutable, so incomplete objects are harmlessly synced on the next run.

## Variables reference

### VPS side (postgres_backup galaxy role)

These are wired automatically in `group_vars/slovo_servers/main.yml`. You generally do **not** need to override them.

| Variable | Default | Description |
| --- | --- | --- |
| `postgres_backup_enabled` | `true` | Enable/disable daily pg_dump |
| `postgres_backup_schedule` | `"30 04 * * *"` | Cron schedule (UTC) |
| `postgres_backup_keep_days` | `7` | Retention: daily copies |
| `postgres_backup_keep_weeks` | `4` | Retention: weekly copies |
| `postgres_backup_keep_months` | `6` | Retention: monthly copies |
| `postgres_backup_extra_opts` | `"-Z9"` | pg_dump extra options (gzip level 9) |

### NAS side (slovo-backup-nas custom role)

Set these in `inventory/host_vars/<nas-host>/vars.yml`.

| Variable | Default | Description |
| --- | --- | --- |
| `slovo_backup_nas_enabled` | `false` | Enable/disable the NAS pull role |
| `slovo_backup_nas_base_path` | `/opt/slovo-backup` | Base dir for keys, known_hosts, bin/ |
| `slovo_backup_nas_vps_host` | `slovo.example.com` | Inventory hostname of the VPS (override in `host_vars/<nas-host>/vars.yml`) |
| `slovo_backup_nas_vps_ssh_port` | `22` | SSH port of the VPS |
| `slovo_backup_nas_postgres_backup_dest` | `/mnt/data/backups/slovo-postgres` | NAS destination for PG dumps |
| `slovo_backup_nas_minio_data_dest` | `/mnt/data/backups/slovo-minio` | NAS destination for MinIO data |
| `slovo_backup_nas_timer_on_calendar` | `*-*-* 06:00:00 UTC` | systemd timer schedule (UTC suffix required) |
| `slovo_backup_nas_timer_randomized_delay_sec` | `15min` | Timer jitter to avoid thundering herd |

## Retention

| Scope | Daily | Weekly | Monthly |
| --- | --- | --- | --- |
| VPS (`slovo-postgres-backup`) | 7 days | 4 weeks | 6 months |
| NAS (mirror) | 1:1 from VPS (`--delete` keeps them in sync) |

The NAS mirror uses rsync `--delete`, so when the VPS rotation removes old dumps, the NAS removes them too on the next pull.

## How to restore

### PostgreSQL

Restore into the running postgres container on the VPS:

```bash
# Find the most recent dump
ls -lt /slovo/postgres-backup/data/

# Decompress and restore (adjust filename)
gunzip -c /slovo/postgres-backup/data/<dump-file>.sql.gz | \
  docker exec -i slovo-postgres psql -U slovo -d slovo
```

For a full database replacement, drop and recreate first:

```bash
docker exec slovo-postgres psql -U slovo -c "DROP DATABASE slovo;"
docker exec slovo-postgres psql -U slovo -c "CREATE DATABASE slovo OWNER slovo;"
gunzip -c /slovo/postgres-backup/data/<dump-file>.sql.gz | \
  docker exec -i slovo-postgres psql -U slovo -d slovo
```

### MinIO

MinIO data is backed up as a raw filesystem copy (rsync of `/slovo/minio/data`). To restore, pull the data from the NAS back to the VPS:

```bash
# On the VPS — pull MinIO data from NAS (disaster recovery):
rsync -az -e "ssh -p 2222" root@nas.example.com:/mnt/data/backups/slovo-minio/ /slovo/minio/data/
# Replace nas.example.com and port 2222 with your NAS SSH endpoint.
```

> **Note:** The backup SSH keys are read-only one-way (NAS→VPS via rrsync). A reverse pull (VPS→NAS) is not provisioned by this playbook. Disaster recovery requires temporary manual SSH access to the NAS — either a password or a temporarily authorized key.

## Operational commands

### Check timer status

```bash
# On the NAS — check the pull timer:
systemctl list-timers | grep slovo
systemctl status slovo-backup-nas.timer
```

### Automatic pull on apply

When the pull script or the systemd service unit changes (or on first install), the handler fires `systemctl start slovo-backup-nas.service` automatically at the end of the Ansible run. The first apply triggers a full initial MinIO sync, which may take a while. Subsequent applies skip the pull unless the templates actually changed.

### Trigger a manual run

```bash
# On the NAS — pull backups now:
systemctl start slovo-backup-nas.service
journalctl -u slovo-backup-nas -f
```

### View logs

```bash
# NAS pull logs:
journalctl -u slovo-backup-nas -f

# VPS backup logs:
journalctl -u slovo-postgres-backup -f
```

## Security notes

- **rrsync-restricted keys**: each SSH key is restricted to read-only access on a single source directory via the `command=` option in `authorized_keys`. The keys cannot execute arbitrary commands, port-forward, or agent-forward.
- **Per-module scoping**: the PostgreSQL backup key can only read `/slovo/postgres-backup/data`, and the MinIO key can only read `/slovo/minio/data`. This is deliberate — `/slovo` contains env files with secrets, so the keys must not have access to the full tree.
- **rrsync path handling**: rrsync interprets the client-supplied source path *relative* to its restricted root (the `command=` directory). The pull script sends `:/` (a bare slash), which maps to the restricted root itself — it does **not** send the absolute VPS path (e.g. `/slovo/postgres-backup/data/`), as that would produce a doubled path (`/slovo/postgres-backup/data/slovo/postgres-backup/data`). The module is selected implicitly by which per-module SSH key is used.
- **TOFU trust**: `StrictHostKeyChecking=accept-new` is used for the initial SSH connection. The VPS host key is added to `known_hosts` on first connect and verified on subsequent runs. If the VPS host key changes (e.g. after a reinstall), delete `/opt/slovo-backup/known_hosts` on the NAS and re-run the playbook.
- **No inbound ports**: the pull model means the VPS does not need any additional open ports — the NAS initiates all SSH connections on port 22.

## Caveats

- The NAS mirror is **not atomic** during uploads. If a MinIO upload is in progress when the pull runs, the rsync may copy a partially-written object. Since MinIO objects are UUID-named and immutable, the incomplete object will be fully synced on the next pull run.
- The `slovo-postgres-backup` service is registered in `devture_systemd_service_manager_services_list_auto` at priority 520 (after postgres at 500, before pgbouncer at 550). The service is enabled/started/restarted by the systemd service manager, not by the role directly. The postgres_backup role sets `postgres_backup_restart_necessary` via `set_fact` during install, which the service manager reads to decide whether a restart is required.

## Applying changes

### One-command shortcuts (recommended)

The justfile ships per-role and umbrella recipes that pass the correct tags (including `start` for service enablement):

```bash
# Set up everything backup-related (postgres-backup + slovo-backup-nas + start):
just setup-backups --ask-vault-pass

# Or install everything:
just install-backups --ask-vault-pass

# Individual roles:
just setup-postgres-backup --ask-vault-pass
just setup-slovo-backup-nas --ask-vault-pass

# Full deployment (all services, not just backups):
just setup-all --ask-vault-pass
```

### Understanding the tags

The `start` tag is required in addition to the setup/install tag. The postgres_backup galaxy role registers its systemd unit via `devture_systemd_service_manager`, which enables and starts services only when the `start` (or `restart`) tag is active. Running `--tags=setup-postgres-backup` alone installs the unit file but does **not** enable or start the service.

Raw ansible-playbook equivalents:

```bash
# postgres-backup only:
ansible-playbook -i inventory/hosts setup.yml \
  --tags=setup-postgres-backup,start --ask-vault-pass

# Both backup roles:
ansible-playbook -i inventory/hosts setup.yml \
  --tags=setup-postgres-backup,setup-slovo-backup-nas,start --ask-vault-pass
```
