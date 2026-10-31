# AGENTS.md

Coding agent instructions for the slovo-propovedi-playbook repository (Ansible automation for the Slovo.Propovedi server infrastructure).

## What this repo is
Ansible playbook provisioning shared infrastructure only (PostgreSQL, PgBouncer, MinIO, xprem OTA, Adminer, Traefik, backups). Applications deploy themselves from their own repos — no application roles here. See `README.md` and `docs/`.

## Commands
```bash
just install-all    # install galaxy roles + run full setup
just setup-all      # run full setup
just lint           # yamllint + ansible-lint
just dry-run        # ansible-playbook --syntax-check
just check          # lint + syntax check
```

## Mandatory Workflows: SDD, Plan-Implement, TDD

Every non-trivial task runs through a workflow BEFORE implementation. Workflow skills live in `.opencode/skills/<name>/SKILL.md` with a byte-identical mirror in `.claude/skills/` (keep both copies in sync). Spec-driven commands live in `.opencode/commands/speckit.*.md` (mirrored in `.claude/commands/`).

| Situation | Workflow | How |
|-----------|----------|-----|
| New service/role, infra topology change, vague requirements | Spec-Driven Development | `/speckit.specify` → `/speckit.clarify` → `/speckit.plan` → `/speckit.tasks` → `/speckit.implement` (`/speckit.constitution` once per repo) |
| Clear multi-step change | Plan → implement | `plan-implement` skill |
| Any broken task/playbook, failed check, unexpected behavior | Debug first | `systematic-debugging` skill |
| Any change to roles/templates/vars (inside any workflow) | Verification-first TDD | `tdd` skill, Mode B: run `just lint` + `just dry-run` BEFORE and AFTER the change; the "failing check" is the lint/syntax failure or the documented gap |
| Always, on every task | Minimal diff | `ponytail` skill |
| Before claiming ANY task done | Done-gate | `verification-before-completion` skill |

Rules:

1. Load the workflow skill via the `skill` tool BEFORE making changes and announce it.
2. No playbook change without a failing check first (tdd Mode B — this repo has no unit-test framework; `yamllint`/`ansible-lint`/`--syntax-check` are the checks).
3. Specs and task lists are repo artifacts under `specs/<NNN-slug>/`; commit them with the change.
4. Opt-out only on explicit user request.
5. Verification commands: `just lint`, `just dry-run`.
6. Never commit `inventory/` (it is a separate nested git repo, gitignored here — contains server addresses/secrets) or `roles/galaxy/` (fetched via `just roles`).

The `specify` CLI is NOT required at runtime — it is a scaffolder used only to (re)generate `.specify/` templates and the speckit commands.

## Documentation
Operational guides live in `docs/` (configuring-playbook, configuring-traefik, configuring-playbook-xprem, configuring-backups, deploying-apps, migration-2026-08-vps). Update the affected doc in the same commit when changing what it describes.
