# nba-infra

Infra glue for the NBA stack. Tracks Compose, proxy, env templates, and ops docs. Portfolio repo.

## Status
- Docs exist. Compose, env templates, proxy, and scripts are pending.

## Topology
- Proxy routes only `/api/*` to the Node API.
- Go feed and Python predictor stay private on the Docker network.
- Frontend stays static on its host.

## How to work
- Keep configs explicit: ports, service names, env vars.
- Do not expose private services.
- Public docs in this repo cover deployment and roadmap.
