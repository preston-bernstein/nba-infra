# nba-infra

[![CI](https://github.com/preston-bernstein/nba-infra/actions/workflows/ci.yml/badge.svg)](https://github.com/preston-bernstein/nba-infra/actions/workflows/ci.yml) [![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

Infra glue for the NBA stack. Tracks Compose, proxy, env templates, and ops docs. Portfolio repo.

## Status

- Docs exist. Local/prod Compose, env template, and local proxy config are present. Scripts are pending.

## Topology

- Proxy routes only `/api/*` to the Node API.
- Go feed and Python predictor stay private on the Docker network.
- Frontend stays static on its host.

## How to work

- Keep configs explicit: ports, service names, env vars.
- Do not expose private services.
- Public docs in this repo cover deployment and roadmap.
- `scripts/up.sh` builds `api/dist` when missing. It runs `npx nx docker:build @nba-analytics-hub/api --skip-nx-cache` in `../nba-analytics-hub` with `NX_ISOLATE_PLUGINS=false` and `NX_DAEMON=false`. Use Node 20 and ensure `api/package.json` includes runtime deps (`@nba-analytics-hub/data-access`, `@nba-analytics-hub/testing`).
- `scripts/up.sh` runs `npx nx reset` and retries once if the API build fails.
- `scripts/up.sh` regenerates `api/dist/package-lock.json` when missing or identical to the root lockfile. Set `SKIP_LOCKFILE_FIX=1` to skip.
- Set `SKIP_API_BUILD=1` to skip the prebuild, `FORCE_API_BUILD=1` to rebuild, or `API_ROOT=/path/to/nba-analytics-hub` to override the repo path. If an old API image is cached, remove it and rebuild compose.
- Predictor data/model live in volumes at `/work/data_cache` and `/work/artifacts`. Override with `PREDICTOR_DATA_CACHE=/path` and `PREDICTOR_ARTIFACTS=/path`.
- `scripts/up.sh` seeds predictor assets when missing. Set `SKIP_PREDICTOR_SEED=1` to skip or use `PREDICTOR_SEED_OFFLINE=1` / `./scripts/up.sh --offline` to seed from fixtures.
- API env for internal services: `GAMES_SERVICE_URL=http://go-feed:4000`, `PREDICTOR_SERVICE_URL=http://predictor:5000`.

## Files

- `docker-compose.yml` (local), `docker-compose.prod.yml` (VPS/prod)
- `.env.example` (no secrets)
- `Caddyfile` (local-only; update with domain + HTTPS later)
- `scripts/` (`up.sh`, `down.sh`, `logs.sh`, `deploy-vps.sh`)
- `DEPLOYMENT.md`, `ROADMAP.md`, `LICENSE`, `CODEOWNERS`
- Repos: Node API `../nba-analytics-hub/api` (Dockerfile), Go feed `../nba-data-service` (Dockerfile), Predictor `../nba-predictor` (Dockerfile.dev)
- Volumes: Go snapshots use named volume `go-data` at `/app/data` and run as root; predictor prod uses cache/artifact volumes.
- Predictor: Compose runs uvicorn (`src.service.app:app` on 5000). Keep the command in sync with the predictor repo if it changes.
