# slovo-propovedi-playbook — just commands
# Run `just` to see available commands.
# Run `just roles` first to install galaxy roles.

# Default recipe — show available commands
default:
    @just --list

# Install/refresh external Ansible galaxy roles and collections
roles:
    @echo "Installing galaxy roles..."
    ansible-galaxy role install -r requirements.yml -p roles/galaxy --force
    @echo "Installing galaxy collections..."
    ansible-galaxy collection install -r requirements.yml --force

# Install all services and start them (full deployment)
install-all *extra_args: (run-tags "install-all,ensure-slovo-users-created,start" extra_args)

# Set up all services and start them (full setup, restarts everything)
setup-all *extra_args: (run-tags "setup-all,ensure-slovo-users-created,start" extra_args)

# Install a single service and start it
install-service service *extra_args: (run-tags "install-" + service + ",start" extra_args)

# Set up a single service and start it
setup-service service *extra_args: (run-tags "setup-" + service + ",start" extra_args)

# --- Per-service shortcuts ---
# Dedicated setup-/install- recipes for each slovo service.
# Equivalent to: just setup-service <name>  /  just install-service <name>
# All recipes include the 'start' tag because every service is registered via
# devture_systemd_service_manager, which enables/starts units only under 'start'.

# Set up slovo-swap and start it
setup-slovo-swap *extra_args: (run-tags "setup-slovo-swap,start" extra_args)

# Install slovo-swap and start it
install-slovo-swap *extra_args: (run-tags "install-slovo-swap,start" extra_args)

# Set up slovo-base and start it
setup-slovo-base *extra_args: (run-tags "setup-slovo-base,start" extra_args)

# Install slovo-base and start it
install-slovo-base *extra_args: (run-tags "install-slovo-base,start" extra_args)

# Set up slovo-buildx and start it
setup-slovo-buildx *extra_args: (run-tags "setup-slovo-buildx,start" extra_args)

# Install slovo-buildx and start it
install-slovo-buildx *extra_args: (run-tags "install-slovo-buildx,start" extra_args)

# Set up slovo-pgbouncer and start it
setup-slovo-pgbouncer *extra_args: (run-tags "setup-slovo-pgbouncer,start" extra_args)

# Install slovo-pgbouncer and start it
install-slovo-pgbouncer *extra_args: (run-tags "install-slovo-pgbouncer,start" extra_args)

# Set up slovo-minio and start it
setup-slovo-minio *extra_args: (run-tags "setup-slovo-minio,start" extra_args)

# Install slovo-minio and start it
install-slovo-minio *extra_args: (run-tags "install-slovo-minio,start" extra_args)

# Set up slovo-adminer and start it
setup-slovo-adminer *extra_args: (run-tags "setup-slovo-adminer,start" extra_args)

# Install slovo-adminer and start it
install-slovo-adminer *extra_args: (run-tags "install-slovo-adminer,start" extra_args)

# Set up postgres-backup and start it
setup-postgres-backup *extra_args: (run-tags "setup-postgres-backup,start" extra_args)

# Install postgres-backup and start it
install-postgres-backup *extra_args: (run-tags "install-postgres-backup,start" extra_args)

# Set up slovo-backup-nas and start it
setup-slovo-backup-nas *extra_args: (run-tags "setup-slovo-backup-nas,start" extra_args)

# Install slovo-backup-nas and start it
install-slovo-backup-nas *extra_args: (run-tags "install-slovo-backup-nas,start" extra_args)

# Set up all backup roles (postgres-backup + slovo-backup-nas) and start them
setup-backups *extra_args: (run-tags "setup-postgres-backup,setup-slovo-backup-nas,start" extra_args)

# Install all backup roles and start them
install-backups *extra_args: (run-tags "install-postgres-backup,install-slovo-backup-nas,start" extra_args)

# Create the admin user (run after install-all or setup-all)
ensure-admin-user *extra_args: (run-tags "ensure-slovo-users-created" extra_args)

# Run ansible-playbook with custom arguments
run +extra_args:
    ansible-playbook -i inventory/hosts setup.yml {{ extra_args }}

# Run ansible-playbook with specific tags
run-tags tags *extra_args: (run "--tags=" + tags extra_args)

# Start all services
start-all: (run-tags "start")

# Start services in a specific group
start-group group: (run-tags "start-group" "--extra-vars=group=" + group)

# Stop all services
stop-all: (run-tags "stop")

# Stop services in a specific group
stop-group group: (run-tags "stop-group" "--extra-vars=group=" + group)

# Check playbook syntax
check: (run "--syntax-check")

# Run the same lint checks as CI (yamllint + ansible-lint)
lint:
    yamllint .
    ansible-lint setup.yml

# Run the same dry-run config check as CI, against the example inventory
dry-run:
    ansible-playbook -i examples/hosts setup.yml --syntax-check

# List all tasks that would run
list-tasks: (run "--list-tasks")

# List all available tags
list-tags: (run "--list-tags")
