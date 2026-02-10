# Deployment Guide

Public-facing notes for running the stack.

## Local integration

- Target topology: proxy -> Node API (`/api/*`) -> private Go/Python services on the Docker network.
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
- Predictor uses `Dockerfile.dev`; Compose sets the uvicorn command. If running outside Compose, use `make serve` or an explicit uvicorn command.

## Production/VPS

- Same topology as local. Differences are env values, images/tags, volumes, and restart policies.
- Compose: `docker-compose.prod.yml` (builds from sibling repos; restart policies set).
- Publish ports 80 and 443. Keep Go/Python internal.
- API image requires a prebuilt `api/dist` with workspace modules; build locally and scp to server.
- Predictor uses `Dockerfile.dev`; keep the serve command in `docker-compose.prod.yml` or switch to a production Dockerfile with a CMD.
- Caddy handles HTTPS automatically via Let's Encrypt when the `DOMAIN` env var is set.

### HTTPS Setup

The Caddyfile reads the `DOMAIN` env var for the production host block. Set it in your `.env` and Caddy obtains and renews certificates automatically.

DNS: Point an A record for your domain to your server's IP.

### Seeding the Predictor

The predictor needs training data and model artifacts. On first deploy, copy them to the server and into the running container:

```bash
# Copy data from local machine to server
scp -r /path/to/nba-predictor/data_cache user@<YOUR_SERVER_IP>:/opt/nba-predictor/
scp -r /path/to/nba-predictor/artifacts user@<YOUR_SERVER_IP>:/opt/nba-predictor/

# Copy into running container
ssh user@<YOUR_SERVER_IP> "docker cp /opt/nba-predictor/data_cache/. nba-infra-predictor-1:/work/data_cache/"
ssh user@<YOUR_SERVER_IP> "docker cp /opt/nba-predictor/artifacts/. nba-infra-predictor-1:/work/artifacts/"
```

Required files:

- `data_cache/games.csv` -- historical game data
- `data_cache/features.csv` -- engineered features
- `artifacts/model.joblib` -- trained model

## Environment

- `.env.example` captures required env vars (no secrets). Keep it in sync with Compose and service configs.

## Commands

- `docker compose up --build`
- `docker compose logs -f`
- `docker compose down`
