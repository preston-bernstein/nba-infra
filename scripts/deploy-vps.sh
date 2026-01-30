#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE_PATH="${COMPOSE_FILE_PATH:-docker-compose.prod.yml}"

docker compose -f "$COMPOSE_FILE_PATH" up --build -d
