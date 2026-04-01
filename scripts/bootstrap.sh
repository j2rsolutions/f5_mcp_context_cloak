#!/usr/bin/env bash
# =============================================================================
# Context Cloak — Local Development Bootstrap
# =============================================================================
#
# This script sets up a local development environment:
#   1. Creates Python venv and installs dependencies
#   2. Starts Postgres in Docker
#   3. Runs schema migrations and seeds sample data
#   4. Starts the MCP server
#
# Prerequisites:
#   - Python 3.11+
#   - Docker
#   - psql client (postgresql-client)
#
# Usage:
#   ./scripts/bootstrap.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

echo "--- Context Cloak Local Bootstrap ---"
echo ""

# 1. Python environment
echo "[1/4] Setting up Python virtual environment..."
if [ ! -d "mcp-server/.venv" ]; then
    python3 -m venv mcp-server/.venv
    echo "  Created venv at mcp-server/.venv"
else
    echo "  Venv already exists"
fi

source mcp-server/.venv/bin/activate
pip install --quiet --upgrade pip
pip install --quiet -r mcp-server/requirements.txt
echo "  Dependencies installed"
echo ""

# 2. Postgres
CONTAINER_NAME="context-cloak-postgres"
echo "[2/4] Starting Postgres..."

if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "  Postgres container already running"
    else
        docker start "$CONTAINER_NAME"
        echo "  Started existing Postgres container"
    fi
else
    docker run -d --name "$CONTAINER_NAME" \
        -e POSTGRES_DB=context_cloak \
        -e POSTGRES_USER=mcpuser \
        -e POSTGRES_PASSWORD=changeme-in-production \
        -p 5432:5432 \
        postgres:16-alpine
    echo "  Created and started Postgres container"
fi

echo "  Waiting for Postgres to accept connections..."
for i in $(seq 1 30); do
    if PGPASSWORD=changeme-in-production psql -h localhost -U mcpuser -d context_cloak -c "SELECT 1" >/dev/null 2>&1; then
        echo "  Postgres is ready"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "  ERROR: Postgres did not become ready in time"
        exit 1
    fi
    sleep 1
done
echo ""

# 3. Database setup
echo "[3/4] Running schema migrations and seeding data..."
PGPASSWORD=changeme-in-production psql -h localhost -U mcpuser -d context_cloak \
    -f mcp-server/sql/001_schema.sql \
    -f mcp-server/sql/002_seed_data.sql
echo "  Database initialized with sample data"
echo ""

# 4. Start MCP server
echo "[4/4] Starting MCP server..."
echo "  Listening on http://localhost:8080"
echo "  Press Ctrl+C to stop"
echo ""

cd mcp-server
POSTGRES_HOST=localhost \
POSTGRES_PORT=5432 \
POSTGRES_DB=context_cloak \
POSTGRES_USER=mcpuser \
POSTGRES_PASSWORD=changeme-in-production \
MCP_SERVER_HOST=0.0.0.0 \
MCP_SERVER_PORT=8080 \
python -m src.server
