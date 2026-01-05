# Roadmap

Public snapshot of planned work.

## Current
- Docs exist. Compose, env template, proxy config, and scripts are pending.

## Next steps
- Add `docker-compose.yml` for local integration (service-name networking; proxy publishes API only).
- Add `.env.example` with explicit env vars (no secrets; consistent names).
- Add proxy config (`Caddyfile` or Nginx) for `/api/*` only with TLS/redirects once domains are known.
- Add `docker-compose.prod.yml` with explicit images and restart policies; keep private services internal.
- Add scripts for up/down/logs/deploy and a concise README walkthrough if needed.

## Guardrails
- Keep topology identical across environments; change config, not architecture.
- Do not expose Go/Python services. Frontend stays static on its host.
- Keep docs terse and free of marketing language.
