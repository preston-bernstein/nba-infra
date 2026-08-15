#!/usr/bin/env bash
set -euo pipefail

COMPOSE_BASE_FILE="${COMPOSE_BASE_FILE:-docker-compose.yml}"
COMPOSE_FILE_PATH="${COMPOSE_FILE_PATH:-docker-compose.prod.yml}"

docker compose -f "$COMPOSE_BASE_FILE" -f "$COMPOSE_FILE_PATH" up --build -d
