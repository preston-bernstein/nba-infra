# Roadmap

Public snapshot of planned work.

## Current

- Local and prod Compose files exist.
- `.env.example` exists with a public env contract (no secrets).
- `Caddyfile` reads the `DOMAIN` env var for production HTTPS plus local `:80`.
- Scripts exist: `scripts/up.sh`, `down.sh`, `logs.sh`, `deploy-vps.sh`.
- README and `DEPLOYMENT.md` document local and prod usage.

## Next steps

- Keep public docs aligned with `docs-internal/*` as configs change.
- Add a short ops runbook (failure modes, predictor seeding, API build notes).
- Decide when to move from local builds to tagged images.

## Guardrails

- Keep topology identical across environments; change config, not architecture.
- Do not expose Go/Python services. Frontend stays static on its host.
- Keep docs terse and free of marketing language.
