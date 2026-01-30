#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE_PATH="${COMPOSE_FILE_PATH:-docker-compose.yml}"

show_help() {
    echo "Usage: ./scripts/logs.sh [service...] [options]"
    echo ""
    echo "Services:"
    echo "  api        Node.js API gateway"
    echo "  go-feed    Go data service (balldontlie)"
    echo "  predictor  Python ML predictor"
    echo "  proxy      Caddy reverse proxy"
    echo "  all        All services (default)"
    echo ""
    echo "Options:"
    echo "  --tail N   Show last N lines (default: all)"
    echo "  --no-follow  Don't follow logs, just print and exit"
    echo ""
    echo "Examples:"
    echo "  ./scripts/logs.sh go-feed          # Follow Go service logs"
    echo "  ./scripts/logs.sh api go-feed      # Follow multiple services"
    echo "  ./scripts/logs.sh --tail 50        # Last 50 lines from all"
    echo "  ./scripts/logs.sh go-feed --tail 20"
}

# Parse arguments
SERVICES=()
TAIL_ARG=""
FOLLOW="-f"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        --tail)
            TAIL_ARG="--tail $2"
            shift 2
            ;;
        --no-follow)
            FOLLOW=""
            shift
            ;;
        all)
            # No service filter = all services
            shift
            ;;
        *)
            SERVICES+=("$1")
            shift
            ;;
    esac
done

# shellcheck disable=SC2086
docker compose -f "$COMPOSE_FILE_PATH" logs $FOLLOW $TAIL_ARG "${SERVICES[@]+"${SERVICES[@]}"}"
