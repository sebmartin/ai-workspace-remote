# No `export` here, deliberately. Exported values reach compose's environment,
# which takes precedence over the `.env` compose reads itself, and make keeps
# the whitespace before an inline `# comment`, so a padded value would win.
# Nothing below needs them exported.
-include .env

SMB_PASSWORD_FILE ?= ./secrets/smb_password
WORKSPACE_UID     ?= 1000
WORKSPACE_GID     ?= 1000

# Same trailing-whitespace hazard, on this side of the fence. A value written
# with an inline comment reaches the recipes below padded, where unquoted it
# word-splits into extra arguments and quoted it names a padded path. Strip
# once here, quote at every use.
WORKSPACE_HOST_PATH    := $(strip $(WORKSPACE_HOST_PATH))
CLAUDE_HOME_HOST_PATH  := $(strip $(CLAUDE_HOME_HOST_PATH))
BACKUP_STATE_HOST_PATH := $(strip $(BACKUP_STATE_HOST_PATH))
SMB_PASSWORD_FILE      := $(strip $(SMB_PASSWORD_FILE))
WORKSPACE_UID          := $(strip $(WORKSPACE_UID))
WORKSPACE_GID          := $(strip $(WORKSPACE_GID))

.PHONY: help dirs smb-password up down restart rebuild logs ps shell login \
        plugins backup-now check env

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

dirs: ## Create the host directories with the right ownership
	sudo mkdir -p "$(WORKSPACE_HOST_PATH)" "$(CLAUDE_HOME_HOST_PATH)/.claude" "$(BACKUP_STATE_HOST_PATH)"
	test -s "$(CLAUDE_HOME_HOST_PATH)/.claude.json" || \
	  printf '{}' | sudo tee "$(CLAUDE_HOME_HOST_PATH)/.claude.json" >/dev/null
	sudo chown -R "$(WORKSPACE_UID):$(WORKSPACE_GID)" \
	  "$(WORKSPACE_HOST_PATH)" "$(CLAUDE_HOME_HOST_PATH)" "$(BACKUP_STATE_HOST_PATH)"

smb-password: ## Generate a random SMB password if there isn't one yet
	@mkdir -p "$(dir $(SMB_PASSWORD_FILE))"
	@test -s "$(SMB_PASSWORD_FILE)" || { \
	  LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 > "$(SMB_PASSWORD_FILE)"; \
	  chmod 600 "$(SMB_PASSWORD_FILE)"; \
	  echo "wrote a new password to $(SMB_PASSWORD_FILE)"; }
	@echo "SMB user: claude"
	@echo "password: $$(cat "$(SMB_PASSWORD_FILE)")"

up: ## Build anything stale and start the stack
	docker compose up -d --build

down: ## Stop the stack
	docker compose down

restart: ## Restart claude-remote, which is the whole update ritual
	docker compose restart claude-remote

rebuild: ## Rebuild from scratch, refreshing base images and apt packages
	docker compose build --pull --no-cache
	docker compose up -d

logs: ## Follow logs
	docker compose logs -f --tail=100

ps: ## Show container status and health
	docker compose ps

shell: ## Shell into claude-remote
	docker compose exec claude-remote bash

# `run`, not `exec`: before the first login the service exits and restarts,
# so there is no running container to exec into.
login: ## Run Claude to do the one-time /login
	docker compose run --rm claude-remote claude

plugins: ## Show which plugin and ref is actually live
	docker compose exec claude-remote claude plugin list --json | jq '[.[] | {id, version, enabled}]'

backup-now: ## Run a snapshot and a mirror immediately
	docker compose exec backup /opt/aiwr/commit.sh
	docker compose exec backup /opt/aiwr/mirror.sh

check: ## Validate the compose file and the shell scripts
	docker compose config -q && echo "compose: ok"
	@command -v shellcheck >/dev/null 2>&1 \
	  && shellcheck -x claude/entrypoint.sh samba/entrypoint.sh backup/entrypoint.sh backup/scripts/*.sh \
	  && echo "shellcheck: ok" \
	  || echo "shellcheck: not installed, skipped"

env: ## Report keys present in .env.example but missing from .env
	@test -f .env || { echo ".env does not exist; cp .env.example .env"; exit 1; }
	@missing=$$(comm -23 \
	  <(grep -oE '^[A-Z_][A-Z0-9_]*=' .env.example | sort -u) \
	  <(grep -oE '^[A-Z_][A-Z0-9_]*=' .env         | sort -u)); \
	if [ -n "$$missing" ]; then echo "missing from .env:"; echo "$$missing" | sed 's/^/  /'; \
	else echo ".env has every key from .env.example"; fi
