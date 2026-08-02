# slovo-propovedi-playbook — just commands
# Run `just` to see available commands.
# Run `just roles` first to install galaxy roles.

# Default recipe — show available commands
default:
    @just --list

# Install/refresh external Ansible galaxy roles
roles:
    @echo "Installing galaxy roles..."
    ansible-galaxy install -r requirements.yml -p roles/galaxy --force

# Install all services and start them (full deployment)
install-all *extra_args: (run-tags "install-all,ensure-slovo-users-created,start" extra_args)

# Set up all services and start them (full setup, restarts everything)
setup-all *extra_args: (run-tags "setup-all,ensure-slovo-users-created,start" extra_args)

# Install a single service and start it
install-service service *extra_args: (run-tags "install-" + service + ",start" extra_args)

# Set up a single service and start it
setup-service service *extra_args: (run-tags "setup-" + service + ",start" extra_args)

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

# List all tasks that would run
list-tasks: (run "--list-tasks")

# List all available tags
list-tags: (run "--list-tags")
