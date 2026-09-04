# Nothing here reads .env. `make init` does, and it is the only thing that
# needs to, which keeps make's include-and-quote rules out of the picture.

.PHONY: help init up down restart rebuild logs ps shell login \
        plugins backup-now check

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

init: ## Set up, or re-check, everything .env describes
	@./scripts/init.sh

up: ## Build anything stale and start the stack. Run this after any .env change
	docker compose up -d --build

down: ## Stop the stack
	docker compose down

restart: ## Restart claude-remote, which picks up a new Claude or plugin version
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

backup-now: ## Run a snapshot and a transcript copy immediately
	docker compose exec backup /opt/aiwr/commit.sh
	docker compose exec backup /opt/aiwr/transcripts.sh

check: ## Validate the compose file and the shell scripts
	docker compose config -q && echo "compose: ok"
	@command -v shellcheck >/dev/null 2>&1 \
	  && shellcheck -x scripts/init.sh claude/entrypoint.sh samba/entrypoint.sh \
	       backup/entrypoint.sh backup/scripts/*.sh \
	  && echo "shellcheck: ok" \
	  || echo "shellcheck: not installed, skipped"
