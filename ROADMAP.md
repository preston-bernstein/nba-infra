# Roadmap

Public snapshot of planned work.

## Current

- Docs exist. Local Compose, env template, and local proxy config are present. Prod Compose added. Scripts are pending.
- Repo names: Node API `nba-analytics-hub`; Go feed `nba-data-service`; Python predictor `nba-predictor`; infra `nba-infra`.
- Paths/Dockerfiles: see `docs-internal/REPO_PATHS.md` for current compose contexts.

## Next steps

- Add `.env.example` with explicit env vars (no secrets; consistent names). **Done.**
- Add proxy config (`Caddyfile` or Nginx) for `/api/*` only with TLS/redirects once domains are known. Local Caddyfile present; swap in domain + HTTPS when chosen.
- Add `docker-compose.prod.yml` with explicit images and restart policies; keep private services internal. **Done.**
- Add scripts for up/down/logs/deploy and a concise README walkthrough if needed.

## Guardrails

- Keep topology identical across environments; change config, not architecture.
- Do not expose Go/Python services. Frontend stays static on its host.
- Keep docs terse and free of marketing language.
