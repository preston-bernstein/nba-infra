# Deployment Guide

Public-facing notes for running the stack.

## Local integration
- Target topology: proxy → Node API (`/api/*`) → private Go/Python services on the Docker network.
- Services build from sibling repos (`../nba-analytics-hub`, `../nba-data-feed`, `../nba-predictor`).
- Compose file pending; when added, use service names, explicit ports, and no public Go/Python ports.

## Production/VPS
- Same topology as local. Differences are env values, images/tags, volumes, and restart policies.
- Publish only the proxy/API port. Keep Go/Python internal.
- Proxy handles TLS and HTTP→HTTPS when a domain is set; only routes `/api/*`.

## Environment
- `.env.example` will capture required env vars once authored. No secrets. Use consistent names (`GO_SERVICE_BASE_URL`, `PREDICTOR_BASE_URL`, `PORT`, `NODE_ENV`).

## Commands (once Compose exists)
- `docker compose up --build`
- `docker compose logs -f`
- `docker compose down`
