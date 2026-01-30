#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE_PATH="${COMPOSE_FILE_PATH:-docker-compose.yml}"
API_ROOT="${API_ROOT:-../nba-analytics-hub}"
API_DIST_DIR="${API_ROOT}/api/dist"
SKIP_API_BUILD="${SKIP_API_BUILD:-}"
FORCE_API_BUILD="${FORCE_API_BUILD:-}"
SKIP_LOCKFILE_FIX="${SKIP_LOCKFILE_FIX:-}"
SKIP_PREDICTOR_SEED="${SKIP_PREDICTOR_SEED:-}"
PREDICTOR_SEED_OFFLINE="${PREDICTOR_SEED_OFFLINE:-}"

ROOT_LOCKFILE="${API_ROOT}/package-lock.json"
DIST_LOCKFILE="${API_DIST_DIR}/package-lock.json"
PREDICTOR_GAMES_PATH="/work/data_cache/games.csv"
PREDICTOR_MODEL_PATH="/work/artifacts/model.joblib"
UP_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --offline)
      PREDICTOR_SEED_OFFLINE="1"
      shift
      ;;
    --skip-predictor-seed)
      SKIP_PREDICTOR_SEED="1"
      shift
      ;;
    *)
      UP_ARGS+=("$1")
      shift
      ;;
  esac
done

run_api_build() {
  NX_ISOLATE_PLUGINS=false NX_DAEMON=false npx nx docker:build @nba-analytics-hub/api --skip-nx-cache
}

predictor_assets_ready() {
  docker compose -f "$COMPOSE_FILE_PATH" run --rm --no-deps predictor \
    sh -c "test -f \"$PREDICTOR_GAMES_PATH\" && test -f \"$PREDICTOR_MODEL_PATH\""
}

seed_predictor() {
  if [[ "$PREDICTOR_SEED_OFFLINE" == "1" ]]; then
    docker compose -f "$COMPOSE_FILE_PATH" run --rm --build --no-deps predictor \
      make pipeline OFFLINE=1 PRESERVE=1
  else
    docker compose -f "$COMPOSE_FILE_PATH" run --rm --build --no-deps predictor \
      make pipeline
  fi
}

if [[ "$SKIP_API_BUILD" == "1" ]]; then
  echo "Skipping API prebuild (SKIP_API_BUILD=1)."
else
  if [[ "$FORCE_API_BUILD" == "1" || ! -f "$API_DIST_DIR/main.js" || ! -d "$API_DIST_DIR/workspace_modules" ]]; then
    if [[ ! -d "$API_ROOT/api" ]]; then
      echo "Missing API repo at $API_ROOT/api. Set API_ROOT to the nba-analytics-hub path."
      exit 1
    fi
    echo "Building API dist in $API_ROOT..."
    (
      cd "$API_ROOT"
      if ! run_api_build; then
        echo "API build failed. Resetting Nx cache and retrying..."
        npx nx reset
        run_api_build
      fi
    )
  else
    echo "API dist found. Skipping prebuild."
  fi
fi

if [[ "$SKIP_LOCKFILE_FIX" == "1" ]]; then
  echo "Skipping API lockfile fix (SKIP_LOCKFILE_FIX=1)."
else
  needs_lockfile_fix="0"
  if [[ -f "$API_DIST_DIR/main.js" ]]; then
    if [[ ! -f "$DIST_LOCKFILE" ]]; then
      needs_lockfile_fix="1"
    elif [[ -f "$ROOT_LOCKFILE" ]] && cmp -s "$DIST_LOCKFILE" "$ROOT_LOCKFILE"; then
      needs_lockfile_fix="1"
    fi
  fi

  if [[ "$needs_lockfile_fix" == "1" ]]; then
    echo "Regenerating API dist lockfile..."
    (
      cd "$API_DIST_DIR"
      npm install --package-lock-only
    )
  fi
fi

if [[ "$SKIP_PREDICTOR_SEED" == "1" ]]; then
  echo "Skipping predictor seed (SKIP_PREDICTOR_SEED=1)."
else
  if ! predictor_assets_ready; then
    echo "Seeding predictor assets..."
    seed_predictor
  fi
fi

docker compose -f "$COMPOSE_FILE_PATH" up --build "${UP_ARGS[@]}"
