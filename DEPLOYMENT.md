# Deployment Guide

Public-facing notes for running the stack.

## Local integration

- Target topology: proxy → Node API (`/api/*`) → private Go/Python services on the Docker network.
- Compose: `docker-compose.yml` builds from sibling repos (`../nba-analytics-hub/api` for Node API, `../nba-data-service` for Go feed, `../nba-predictor` for Python predictor).
- `scripts/up.sh` builds `api/dist` when missing. It runs `npx nx docker:build @nba-analytics-hub/api --skip-nx-cache` in `../nba-analytics-hub` with `NX_ISOLATE_PLUGINS=false` and `NX_DAEMON=false`. Use Node 20 and ensure `api/package.json` includes runtime deps (`@nba-analytics-hub/data-access`, `@nba-analytics-hub/testing`).
- `scripts/up.sh` runs `npx nx reset` and retries once if the API build fails.
- `scripts/up.sh` regenerates `api/dist/package-lock.json` when missing or identical to the root lockfile. Set `SKIP_LOCKFILE_FIX=1` to skip.
- Set `SKIP_API_BUILD=1` to skip the prebuild, `FORCE_API_BUILD=1` to rebuild, or `API_ROOT=/path/to/nba-analytics-hub` to override the repo path. If the API image was built without workspace modules, remove the old image and rebuild compose to force a fresh context.
- Predictor data/model live in volumes at `/work/data_cache` and `/work/artifacts`. Override with `PREDICTOR_DATA_CACHE=/path` and `PREDICTOR_ARTIFACTS=/path`.
- `scripts/up.sh` seeds predictor assets when missing. Set `SKIP_PREDICTOR_SEED=1` to skip or use `PREDICTOR_SEED_OFFLINE=1` / `./scripts/up.sh --offline` to seed from fixtures.
- API env vars should point to internal services: `GAMES_SERVICE_URL=http://go-feed:4000`, `PREDICTOR_SERVICE_URL=http://predictor:5000`.
- Proxy publishes only port 80. Internal ports: API 3000, Go feed 4000, predictor 5000.
- Go snapshots: Go feed writes under `/app/data`; Compose mounts a named volume (`go-data`) and runs the service as root to keep it writable/persistent.
- Predictor: Dockerfile.dev exits after setup (no long-running CMD). Add a uvicorn CMD/entrypoint before using it in production; current Compose will see it exit immediately.

## Production/VPS

- Same topology as local. Differences are env values, images/tags, volumes, and restart policies.
- Compose: `docker-compose.prod.yml` (builds from sibling repos; restart policies set).
- Publish only the proxy/API port (80). Keep Go/Python internal.
- API image also requires a prebuilt `api/dist` with workspace modules; build it in `nba-analytics-hub` before composing.
- Proxy handles TLS and HTTP→HTTPS when a domain is set; only routes `/api/*`. Current Caddyfile is local-only (`:80`); swap to domain + HTTPS when chosen.

## Environment

- `.env.example` will capture required env vars once authored. No secrets. Use consistent names (`GO_SERVICE_BASE_URL`, `PREDICTOR_BASE_URL`, `PORT`, `NODE_ENV`).

## Commands (once Compose exists)

- `docker compose up --build`
- `docker compose logs -f`
- `docker compose down`
