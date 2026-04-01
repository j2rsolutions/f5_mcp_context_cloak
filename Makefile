.PHONY: setup db-up db-down db-init mcp-server docker-build clean help

VENV := mcp-server/.venv
PYTHON := $(VENV)/bin/python
PIP := $(VENV)/bin/pip
DB_CONTAINER := context-cloak-postgres

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-18s %s\n", $$1, $$2}'

setup: ## Create Python venv and install dependencies
	python3 -m venv $(VENV)
	$(PIP) install --upgrade pip
	$(PIP) install -r mcp-server/requirements.txt

db-up: ## Start local Postgres container
	docker run -d --name $(DB_CONTAINER) \
		-e POSTGRES_DB=context_cloak \
		-e POSTGRES_USER=mcpuser \
		-e POSTGRES_PASSWORD=changeme-in-production \
		-p 5432:5432 \
		postgres:16-alpine
	@echo "Waiting for Postgres to be ready..."
	@sleep 3

db-down: ## Stop and remove local Postgres container
	docker rm -f $(DB_CONTAINER) 2>/dev/null || true

db-init: ## Run schema and seed SQL against local Postgres
	PGPASSWORD=changeme-in-production psql -h localhost -U mcpuser -d context_cloak \
		-f mcp-server/sql/001_schema.sql \
		-f mcp-server/sql/002_seed_data.sql

mcp-server: ## Run MCP server locally
	cd mcp-server && POSTGRES_HOST=localhost POSTGRES_PORT=5432 \
		POSTGRES_DB=context_cloak POSTGRES_USER=mcpuser \
		POSTGRES_PASSWORD=changeme-in-production \
		$(abspath $(PYTHON)) -m src.server

docker-build: ## Build MCP server Docker image
	docker build -t context-cloak-mcp-server:latest mcp-server/

clean: ## Remove venv and temp files
	rm -rf $(VENV)
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
