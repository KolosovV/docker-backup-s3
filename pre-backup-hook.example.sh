#!/usr/bin/env bash
# ==============================================================================
# pre-backup-hook.sh — an example of a CUSTOM hook
#
# ⚠️ IMPORTANT: the auto-dump of PostgreSQL / MySQL / MariaDB / Redis / MongoDB
# runs AUTOMATICALLY in docker-backup.sh.
# This hook is needed ONLY for:
#   - non-standard databases (ClickHouse, InfluxDB, Elasticsearch, Cassandra, ...)
#   - custom dump logic (e.g. an export from an API)
#   - cleaning up temporary files
#   - preparing data before the backup (an export from the application)
#
# Put this file into the project folder (next to docker-compose.yml) and run:
#   chmod +x pre-backup-hook.sh
#
# Available environment variables:
#   COMPOSE_PROJECT      — project name (e.g. "myapp")
#   PROJECT_DIR          — absolute path to the folder (e.g. "/opt/myapp")
#   BACKUP_TIMESTAMP     — backup timestamp (e.g. "2026-05-06_03-00-00")
# ==============================================================================
set -euo pipefail
cd "$PROJECT_DIR"

# ============================================================================
# EXAMPLE 1: ClickHouse — BACKUP TO Disk
# ============================================================================
# CLICKHOUSE_CONTAINER=$(docker ps --format '{{.Names}}' \
#     --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" \
#     | grep clickhouse | head -1)
#
# if [[ -n "$CLICKHOUSE_CONTAINER" ]]; then
#     mkdir -p "${PROJECT_DIR}/db-dumps"
#     docker exec "$CLICKHOUSE_CONTAINER" clickhouse-client --query \
#         "BACKUP DATABASE my_db TO Disk('backups', '${BACKUP_TIMESTAMP}.zip')"
# fi

# ============================================================================
# EXAMPLE 2: Elasticsearch — snapshot
# ============================================================================
# ES_CONTAINER=$(docker ps --format '{{.Names}}' \
#     --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" \
#     | grep elasticsearch | head -1)
#
# if [[ -n "$ES_CONTAINER" ]]; then
#     curl -X PUT "http://localhost:9200/_snapshot/my_repo/snap_${BACKUP_TIMESTAMP}?wait_for_completion=true"
# fi

# ============================================================================
# EXAMPLE 3: Cleaning up temporary files before the backup
# ============================================================================
# # Delete old application logs
# rm -f "${PROJECT_DIR}"/app/storage/logs/*.log
# # Clear the framework cache
# docker exec "${COMPOSE_PROJECT}-app-1" php artisan cache:clear

# ============================================================================
# EXAMPLE 4: Exporting data from an API
# ============================================================================
# # The token goes in a curl config on a pipe: as -H "…" it would be on the command line, visible in ps
# mkdir -p "${PROJECT_DIR}/api-exports"
# curl -s "http://localhost:8080/api/admin/export" \
#     -K <(printf 'header = "Authorization: Bearer %s"\n' "$API_TOKEN") \
#     -o "${PROJECT_DIR}/api-exports/data_${BACKUP_TIMESTAMP}.json"

echo "[hook] Custom pre-backup hook finished successfully"
