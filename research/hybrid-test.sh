#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Local Hybrid Test: Superset 2.1.0 web server + Master MCP service
# Both pointing at the same database after schema upgrade.
#
# Prerequisites:
#   - docker compose up (current dev stack running)
#   - superset-db-1 and superset-superset-1 containers are healthy
#
# Usage:
#   bash research/hybrid-test.sh [setup|upgrade|verify|mcp|cleanup]
#
# Run all phases in order:
#   setup   → create test DB and initialize with 2.1.0 schema
#   upgrade → run db upgrade + superset init with master code
#   verify  → check 2.1.0 still responds after upgrade
#   mcp     → start MCP service (master) against test DB and run a health check
#   cleanup → stop and remove test containers + test database
# ---------------------------------------------------------------------------

set -euo pipefail

# ── Config ──────────────────────────────────────────────────────────────────
TEST_DB="superset_21_test"
DB_URI="postgresql://superset:superset@db:5432/${TEST_DB}"
SECRET_KEY="local-hybrid-test-only-abc123XYZ"
# 2.1.0 image hardcodes SQLite — must mount a config file to override SQLALCHEMY_DATABASE_URI
# This file is written to /tmp and mounted into every 2.1.0 container at run time
SUPERSET_21_CONFIG="/tmp/superset_21_test_config.py"
NETWORK="superset_default"
SUPERSET_21_CONTAINER="superset-21-test"
SUPERSET_21_PORT=8090
MCP_TEST_PORT=5009
MASTER_CONTAINER="superset-superset-1"
DB_CONTAINER="superset-db-1"

# ── Helpers ─────────────────────────────────────────────────────────────────
log()  { echo "▶ $*"; }
ok()   { echo "✔ $*"; }
warn() { echo "⚠ $*"; }

# ── Phase 1: setup ──────────────────────────────────────────────────────────
cmd_setup() {
    log "Creating test database '${TEST_DB}' in postgres..."
    docker exec "${DB_CONTAINER}" createdb -U superset "${TEST_DB}" 2>/dev/null \
        && ok "Database created" \
        || warn "Database may already exist — continuing"

    log "Writing 2.1.0 config override to ${SUPERSET_21_CONFIG}..."
    cat > "${SUPERSET_21_CONFIG}" << EOF
# Minimal config override for hybrid test — mounts into /app/pythonpath/
SQLALCHEMY_DATABASE_URI = "${DB_URI}"
SECRET_KEY = "${SECRET_KEY}"
EOF
    ok "Config file written"

    log "Pulling apache/superset:2.1.0 (first run only, ~1.5 GB)..."
    docker pull --platform linux/amd64 apache/superset:2.1.0

    log "Running superset db upgrade with 2.1.0 image (initializes 2.1.0 schema)..."
    docker run --rm \
        --platform linux/amd64 \
        --network "${NETWORK}" \
        -v "${SUPERSET_21_CONFIG}:/app/pythonpath/superset_config.py:ro" \
        apache/superset:2.1.0 \
        superset db upgrade
    ok "2.1.0 schema applied"

    log "Creating admin user in 2.1.0 DB..."
    docker run --rm \
        --platform linux/amd64 \
        --network "${NETWORK}" \
        -v "${SUPERSET_21_CONFIG}:/app/pythonpath/superset_config.py:ro" \
        apache/superset:2.1.0 \
        superset fab create-admin \
            --username admin \
            --firstname Admin \
            --lastname User \
            --email admin@test.com \
            --password admin
    ok "Admin user created"

    log "Running superset init with 2.1.0 (creates Admin/Gamma/Alpha roles and permissions)..."
    docker run --rm \
        --platform linux/amd64 \
        --network "${NETWORK}" \
        -v "${SUPERSET_21_CONFIG}:/app/pythonpath/superset_config.py:ro" \
        apache/superset:2.1.0 \
        superset init
    ok "Roles and permissions initialized"

    log "Starting 2.1.0 web server on port ${SUPERSET_21_PORT}..."
    docker run -d \
        --platform linux/amd64 \
        --name "${SUPERSET_21_CONTAINER}" \
        --network "${NETWORK}" \
        -p "${SUPERSET_21_PORT}:8088" \
        -v "${SUPERSET_21_CONFIG}:/app/pythonpath/superset_config.py:ro" \
        apache/superset:2.1.0 \
        superset run -p 8088 -h 0.0.0.0 --with-threads
    ok "2.1.0 container started"

    log "Waiting for 2.1.0 to become healthy..."
    for i in $(seq 1 20); do
        if docker exec "${SUPERSET_21_CONTAINER}" \
               curl -sf http://localhost:8088/health >/dev/null 2>&1; then
            ok "2.1.0 is healthy at http://localhost:${SUPERSET_21_PORT}"
            break
        fi
        echo "  attempt $i/20..."
        sleep 3
    done

    echo ""
    echo "┌─────────────────────────────────────────────────────────┐"
    echo "│  2.1.0 running at  http://localhost:${SUPERSET_21_PORT}             │"
    echo "│  Login: admin / admin                                   │"
    echo "│                                                         │"
    echo "│  BEFORE running upgrade, verify these work:             │"
    echo "│    ✔ Login at http://localhost:${SUPERSET_21_PORT}                  │"
    echo "│    ✔ Settings → Security → Access Requests (note: exists)│"
    echo "│    ✔ Home dashboard loads                               │"
    echo "└─────────────────────────────────────────────────────────┘"
}

# ── Phase 2: upgrade ────────────────────────────────────────────────────────
cmd_upgrade() {
    log "Running superset db upgrade with MASTER code against '${TEST_DB}'..."
    docker exec \
        -e DATABASE_DB="${TEST_DB}" \
        "${MASTER_CONTAINER}" \
        superset db upgrade
    ok "db upgrade complete"

    log "Running superset init with MASTER code (syncs new permissions)..."
    docker exec \
        -e DATABASE_DB="${TEST_DB}" \
        "${MASTER_CONTAINER}" \
        superset init
    ok "superset init complete"

    echo ""
    echo "┌──────────────────────────────────────────────────────────────┐"
    echo "│  Schema upgraded. Now verify the 2.1.0 web server AFTER upgrade│"
    echo "│                                                              │"
    echo "│  Test at http://localhost:${SUPERSET_21_PORT}:                          │"
    echo "│    ✔ Login still works (admin / admin)                      │"
    echo "│    ✔ Home dashboard loads                                   │"
    echo "│    ✔ Charts / Datasets pages load                           │"
    echo "│    ✔ SQL Lab works                                          │"
    echo "│    ✗ Settings → Security → Access Requests → EXPECTED ERROR │"
    echo "└──────────────────────────────────────────────────────────────┘"
}

# ── Phase 3: verify 2.1.0 health ────────────────────────────────────────────
cmd_verify() {
    log "Checking 2.1.0 health endpoint..."
    STATUS=$(docker exec "${SUPERSET_21_CONTAINER}" \
        curl -s -o /dev/null -w "%{http_code}" http://localhost:8088/health)
    if [ "${STATUS}" = "200" ]; then
        ok "2.1.0 /health → ${STATUS} (running)"
    else
        warn "2.1.0 /health → ${STATUS}"
    fi

    log "Checking login page (checks DB connectivity)..."
    STATUS=$(docker exec "${SUPERSET_21_CONTAINER}" \
        curl -s -o /dev/null -w "%{http_code}" http://localhost:8088/login/)
    if [ "${STATUS}" = "200" ]; then
        ok "2.1.0 /login/ → ${STATUS} (DB connection works)"
    else
        warn "2.1.0 /login/ → ${STATUS}"
    fi

    log "Checking Access Requests page (expected to fail after upgrade)..."
    STATUS=$(docker exec "${SUPERSET_21_CONTAINER}" \
        curl -sf -o /dev/null -w "%{http_code}" http://localhost:8088/accessrequestsmodelview/list/ \
        2>/dev/null || echo "error")
    echo "  Access Requests → HTTP ${STATUS} (expected: 5xx or error after drop)"
}

# ── Phase 4: MCP service ─────────────────────────────────────────────────────
cmd_mcp() {
    log "Starting MCP service (master code) against '${TEST_DB}' on port ${MCP_TEST_PORT}..."

    # Start MCP in background inside the master container.
    # Unset GOOGLE_CLIENT_ID/SECRET so _mcp_google_auth_factory returns None
    # (its built-in guard), which disables the OAuth middleware and allows
    # MCP_DEV_USERNAME=admin to be used as the authenticated user.
    docker exec -d \
        -e DATABASE_DB="${TEST_DB}" \
        -e MCP_DEV_USERNAME=admin \
        -e GOOGLE_CLIENT_ID="" \
        -e GOOGLE_CLIENT_SECRET="" \
        "${MASTER_CONTAINER}" \
        bash -c "superset mcp run --host 0.0.0.0 --port ${MCP_TEST_PORT} > /tmp/mcp-test.log 2>&1"

    log "Waiting for MCP to start..."
    for i in $(seq 1 15); do
        if docker exec "${MASTER_CONTAINER}" \
               curl -sf "http://localhost:${MCP_TEST_PORT}/.well-known/oauth-authorization-server" \
               >/dev/null 2>&1; then
            ok "MCP is up on port ${MCP_TEST_PORT}"
            break
        fi
        echo "  attempt $i/15..."
        sleep 2
    done

    log "Testing MCP health_check tool..."
    docker exec "${MASTER_CONTAINER}" \
        curl -s -X POST \
        -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"health_check","arguments":{}},"id":1}' \
        "http://localhost:${MCP_TEST_PORT}/mcp" | python3 -m json.tool 2>/dev/null || true

    log "MCP startup log (last 20 lines):"
    docker exec "${MASTER_CONTAINER}" tail -20 /tmp/mcp-test.log 2>/dev/null || true

    echo ""
    echo "┌──────────────────────────────────────────────────────────────┐"
    echo "│  MCP service (master) running against upgraded '${TEST_DB}' │"
    echo "│  Using MCP_DEV_USERNAME=admin (no OAuth for this test)      │"
    echo "│                                                              │"
    echo "│  Both services are now running:                             │"
    echo "│    Superset 2.1.0  http://localhost:${SUPERSET_21_PORT}  (web UI)   │"
    echo "│    MCP (master)    port ${MCP_TEST_PORT} inside container          │"
    echo "└──────────────────────────────────────────────────────────────┘"
}

# ── Phase 5: cleanup ─────────────────────────────────────────────────────────
cmd_cleanup() {
    log "Stopping and removing 2.1.0 test container..."
    docker stop "${SUPERSET_21_CONTAINER}" 2>/dev/null && \
        docker rm "${SUPERSET_21_CONTAINER}" 2>/dev/null || true
    ok "Container removed"

    log "Dropping test database '${TEST_DB}'..."
    docker exec "${DB_CONTAINER}" dropdb -U superset --if-exists "${TEST_DB}"
    ok "Database dropped"

    log "Stopping test MCP process (if running)..."
    docker exec "${MASTER_CONTAINER}" bash -c \
        "ps aux | grep 'mcp run.*${MCP_TEST_PORT}' | grep -v grep | awk '{print \$2}' | xargs -r kill" \
        2>/dev/null || true
    ok "Done — test environment cleaned up"
}

# ── Dispatch ─────────────────────────────────────────────────────────────────
PHASE="${1:-help}"
case "${PHASE}" in
    setup)   cmd_setup   ;;
    upgrade) cmd_upgrade ;;
    verify)  cmd_verify  ;;
    mcp)     cmd_mcp     ;;
    cleanup) cmd_cleanup ;;
    all)
        cmd_setup
        echo ""
        read -rp "Press Enter after verifying 2.1.0 works BEFORE upgrade > "
        cmd_upgrade
        echo ""
        read -rp "Press Enter after manually verifying 2.1.0 works AFTER upgrade > "
        cmd_verify
        cmd_mcp
        echo ""
        read -rp "Press Enter to clean up > "
        cmd_cleanup
        ;;
    *)
        echo "Usage: $0 [setup|upgrade|verify|mcp|cleanup|all]"
        echo ""
        echo "  setup    Create test DB, initialize 2.1.0 schema, start 2.1.0 web server"
        echo "  upgrade  Run db upgrade + superset init with master code"
        echo "  verify   Automated health checks on 2.1.0 after upgrade"
        echo "  mcp      Start MCP (master) against test DB, run health check"
        echo "  cleanup  Stop containers and drop test database"
        echo "  all      Run all phases interactively (recommended)"
        ;;
esac
