# Requirements: nba-infra Desktop-Agent-to-XPS-Agent Migration

## Problem statement
nba-infra runs a desktop-only instance of the NBA stack on the `desktop-agent` host, started by a manual `docker compose` command and defined in `docker-compose.desktop.yml`. This instance must move to the `xps-agent` host. Preston needs the three running services, their data, and their configuration to keep working on the new host, with no changes to the production deployment on the DigitalOcean droplet (`nba-api.prestonbernstein.com`) and no changes to any application's source code. This move follows the same pattern used for a prior migration (fashion-monitor) between the same two hosts, which found real gaps — wrong assumed file paths, and a container that crash-looped because a config file didn't land where it expected. This document sets requirements to avoid repeating those gaps.

## Users / stakeholders
- Preston Bernstein — owns the migration, runs every step, holds SSH access to both hosts.
- desktop-agent host — current runtime for the instance being migrated; keeps a rollback copy after cutover.
- xps-agent host — new runtime for the instance.
- nba-infra repo (compose/orchestration) — the repo this work happens in.
- nba-analytics-hub, nba-data-service, nba-predictor — sibling repos whose built containers run under this instance; their source code and API contracts must not change.
- Production DigitalOcean droplet deployment (`nba-api.prestonbernstein.com`) — must stay untouched by this migration.

## Functional requirements

1. The system shall create an `nba-app` service user on xps-agent using an idempotent `useradd`-style pattern (safe to run more than once) with no UID pinned to a specific number.
2. The system shall create the directory `/opt/docker/nba-app/` on xps-agent, owned by the `nba-app` service user.
3. The system shall place four sibling repo checkouts side by side inside `/opt/docker/nba-app/` on xps-agent: `nba-infra`, `nba-analytics-hub`, `nba-data-service`, `nba-predictor` — matching the layout on desktop-agent.
4. The system shall migrate each of the three named Docker volumes (`go-data`, `predictor-data-cache`, `predictor-artifacts`) from desktop-agent to xps-agent using a tar-based `docker volume` export/import over SSH, preserving file contents (not recreating the volumes empty).
5. The system shall verify each migrated volume's contents against the source using a checksum comparison (for example `sha256sum` over the exported tar or over each file) before the migration is considered complete for that volume.
6. The system shall verify the live location and contents of the `.env` file on desktop-agent (`/opt/docker/nba-app/.env`, parent directory, sibling to the four repo checkouts) against the actual running host state before copying it, rather than trusting this document's or any prior document's stated path.
7. The system shall require a human operator — not an agent tool call — to transfer the `.env` file's contents from desktop-agent to xps-agent, so the `BALLDONTLIE_API_KEY` secret and the file's other ~10 variables never pass through a session transcript.
8. The system shall place the transferred `.env` file at `/opt/docker/nba-app/.env` on xps-agent (parent directory, sibling to the four repo checkouts), matching the source layout.
9. The system shall preserve all ~10 environment variables from the source `.env` file without renaming, removing, or changing the value of any variable during the transfer (`BALLDONTLIE_API_KEY`, `NODE_ENV`, `API_PORT`, `GAMES_SERVICE_URL`, `PREDICTOR_SERVICE_URL`, `GO_FEED_PORT`, `PROVIDER`, `BALLDONTLIE_BASE_URL`, `BALLDONTLIE_TIMEZONE`, `PREDICTOR_PORT`).
10. The system shall start all three services (`api`, `go-feed`, `predictor`) on xps-agent using the same command pattern as desktop-agent: `docker compose -f docker-compose.desktop.yml --project-directory /opt/docker/nba-app up -d`, run from the `nba-infra` checkout under `/opt/docker/nba-app/`.
11. The system shall run the `api` service on xps-agent bound to host port 3020, mapped to container port 3000, matching desktop-agent.
12. The system shall run `go-feed` and `predictor` as internal-only services on xps-agent (no host port mapping), matching desktop-agent.
13. The system shall run `go-feed` as the root user (uid 0) on xps-agent, matching desktop-agent's requirement for volume writability.
14. The system shall configure each service's `restart: unless-stopped` policy on xps-agent, matching desktop-agent, so the instance survives a host reboot without any added systemd unit, cron job, or wrapper script.
15. The system shall confirm, after startup, that the `api` service on xps-agent depends on and can reach both `go-feed` and `predictor` over the Docker network, before marking the migration verified.
16. The system shall confirm, after startup, that each of the three containers on xps-agent reaches a running state and stays running for at least 10 minutes of continuous running state with zero restarts (`RestartCount=0`), observed via polling, before marking the migration verified. This threshold is set from live investigation confirming all three containers (`api`, `go-feed`, `predictor`) showed `RestartCount=0` with no crash-looping after 8+ hours of operation on desktop-agent; `predictor`'s logs show brief internal start/stop cycles from Uvicorn's own reload behavior, not container-level restarts.
17. The system shall confirm, after startup, that each container's data files exist at the exact path the container reads from inside xps-agent — not only that a sync step ran — before marking the migration verified: `go-feed`'s `/app/data` (backed by volume `go-data`), and `predictor`'s `/work/data_cache` (backed by volume `predictor-data-cache`) and `/work/artifacts` (backed by volume `predictor-artifacts`).
18. The system shall leave the docker-compose.desktop.yml service definitions (ports, dependencies, restart policy, volume names) unchanged from their desktop-agent values, so this migration changes deployment target only, not topology.
19. The system shall NOT modify `docker-compose.prod.yml`, the production/VPS section of `DEPLOYMENT.md`, the `Caddyfile`, or any configuration tied to the DigitalOcean droplet deployment.
20. The system shall NOT modify application source code, domain models, or API contracts in `nba-analytics-hub`, `nba-data-service`, or `nba-predictor`.
21. The system shall keep the desktop-agent copy of the instance (containers, volumes, and `.env` file) in place and available for rollback for 7 days after cutover, rather than deleting it immediately.
22. The system shall exclude any AI-assistant attribution (mentions of Claude, Anthropic, or any automated assistant) from every commit message, code comment, and document this migration produces; all work is attributed to Preston Bernstein.
23. The system shall NOT attach any VPN or egress-tunnel network to these services, since none of the three services (plain outbound calls to balldontlie.io, and two internal-only services) requires one.
24. The system shall grant the `nba-app` service user sufficient Docker daemon access on xps-agent (for example, membership in the host's `docker` group) to run `docker` and `docker compose` commands without additional privilege elevation, since every step of this migration after user creation invokes Docker as this user.
25. The system shall pin each of the three sibling repo clones on xps-agent (`nba-analytics-hub`, `nba-data-service`, `nba-predictor`) to the exact commit SHA currently checked out on the corresponding desktop-agent repo, and shall flag as a blocker any desktop-agent checkout with uncommitted local changes (dirty working tree) before proceeding.
26. The system shall verify the actual live Docker volume names and container names on desktop-agent before relying on them elsewhere in this migration, rather than assuming values from this or any prior document. Live investigation confirmed: volume names are `nba-infra_go-data`, `nba-infra_predictor-data-cache`, `nba-infra_predictor-artifacts` (underscore-prefixed); container names are `nba-infra-api-1`, `nba-infra-go-feed-1`, `nba-infra-predictor-1` (hyphen-separated, Docker Compose v2's naming convention, not the older v1 underscore style). This verification shall be re-run and reconciled against actual live state during implementation, in case desktop-agent's state has changed since this document was written.

## Non-functional requirements
- Combined size of the three migrated volumes is small (under 20KB today); the migration procedure must still checksum-verify every byte, not rely on the small size to skip verification.
- The `.env` file transfer must never appear in any agent-readable log, transcript, or tool output — operator-run only, per this fleet's secrets-handling convention.
- The migration must be reversible: desktop-agent's containers, volumes, and `.env` file remain intact and startable until the rollback window ends.
- No new host-level scheduling (systemd, cron) is introduced; the instance's availability after a reboot depends only on Docker's own `restart: unless-stopped` policy, matching desktop-agent.

## Constraints
- This migration is a configuration and deployment-target change only — same service topology (three services, three volumes, one `.env` file), different host. It is explicitly NOT an architectural change, per nba-infra's own stated philosophy that "deployment mode changes configuration, not architecture."
- Must not touch `docker-compose.prod.yml`, the production/VPS section of `DEPLOYMENT.md`, the `Caddyfile`, or anything tied to the DigitalOcean droplet at `nba-api.prestonbernstein.com`.
- Must not add application source code or change domain models or API contracts in `nba-analytics-hub`, `nba-data-service`, or `nba-predictor` — this migration touches only deployment and orchestration surfaces (compose files, `.env`, host-side setup).
- Must not mention any AI assistant in commit messages, descriptions, or documentation produced by this work; attribute all work to Preston Bernstein.
- Must follow the fleet's CONVENTIONS.md rule that secrets are transferred by a human operator, never through an agent tool call whose output lands in a session transcript.
- Must confirm the actual live path and contents of the `.env` file on desktop-agent before relying on it, since a prior migration on this host pair found the assumed path did not match the real host state.
- Must place each migrated volume's data where its container actually reads it, since a prior migration on this host pair found a container crash-looping because a sync step didn't place a file where the container expected it.
- The `nba-app` service user must be created with an idempotent pattern and no pinned UID, matching the pattern established for the prior fashion-monitor migration on this host pair.
- Docker Engine and the Docker Compose v2 plugin are required on xps-agent before this migration can proceed; live investigation has already confirmed both are present and functional on xps-agent, so this is a confirmed prerequisite, not an open risk.

## Out of scope
- Any change to the production DigitalOcean droplet deployment, `docker-compose.prod.yml`, the production section of `DEPLOYMENT.md`, or the `Caddyfile`.
- Any change to application source code, domain models, or API contracts in `nba-analytics-hub`, `nba-data-service`, or `nba-predictor`.
- Adding a systemd unit, cron job, or wrapper script to manage the instance on xps-agent — the instance continues to rely on Docker's `restart: unless-stopped` policy only, matching desktop-agent.
- Adding a VPN or egress tunnel for any of the three services.
- Changing the instance's topology, port mappings, service dependencies, or volume names.
- Rotating or changing the value of `BALLDONTLIE_API_KEY` or any other `.env` variable.
- Decommissioning or deleting desktop-agent's copy of the instance — that happens only after the rollback window ends, and is a separate action from this migration.

## Acceptance criteria
1. An `nba-app` service user exists on xps-agent, created by an idempotent `useradd`-style step with no pinned UID.
2. `/opt/docker/nba-app/` exists on xps-agent, owned by `nba-app`, containing the four sibling repo checkouts (`nba-infra`, `nba-analytics-hub`, `nba-data-service`, `nba-predictor`).
3. Each of the three named volumes (`go-data`, `predictor-data-cache`, `predictor-artifacts`) exists on xps-agent with contents that checksum-match the corresponding volume on desktop-agent at the time of export.
4. `/opt/docker/nba-app/.env` exists on xps-agent, containing exactly these 10 variables from the desktop-agent source file with unchanged values: `BALLDONTLIE_API_KEY`, `NODE_ENV`, `API_PORT`, `GAMES_SERVICE_URL`, `PREDICTOR_SERVICE_URL`, `GO_FEED_PORT`, `PROVIDER`, `BALLDONTLIE_BASE_URL`, `BALLDONTLIE_TIMEZONE`, `PREDICTOR_PORT` — transferred by a human operator with no agent tool call in the transfer path.
5. Running `docker compose -f docker-compose.desktop.yml --project-directory /opt/docker/nba-app up -d` from the `nba-infra` checkout on xps-agent brings up all three containers (`api`, `go-feed`, `predictor`).
6. An HTTP GET request to `http://xps-agent:3020/` (or the `api` service's actual root/health path, if one exists — confirming the exact route requires inspecting the Node API's route table in the sibling nba-analytics-hub repo, which is out of this repo's scope) returns an HTTP response in the 200–299 range within 5 seconds.
7. The `go-feed` and `predictor` containers show no host port mapping and are reachable from the `api` container over the Docker network.
8. The `go-feed` container runs as uid 0 on xps-agent.
9. All three containers remain in a running state, with zero restarts (`RestartCount=0`) and no crash loop, for at least 10 minutes after startup on xps-agent, observed via polling — matching pre-migration behavior on desktop-agent, where all three containers ran 8+ hours with zero restarts.
10. `go-feed`'s `/app/data` and `predictor`'s `/work/data_cache` and `/work/artifacts` are confirmed present and populated at those exact container paths on xps-agent (not just confirmed synced to the host).
11. `docker-compose.prod.yml`, the production section of `DEPLOYMENT.md`, and the `Caddyfile` show no diff from their pre-migration state.
12. `nba-analytics-hub`, `nba-data-service`, and `nba-predictor` show no source-code diff from their pre-migration state.
13. Every commit message and document produced by this migration contains no mention of Claude, Anthropic, or any automated assistant, and attributes work to Preston Bernstein.
14. desktop-agent's containers, volumes, and `.env` file remain intact and unstopped through the end of the 7-day rollback window.
15. No systemd unit, cron job, or wrapper script was added on xps-agent to manage this instance.
16. `docker-compose.desktop.yml` itself shows no diff from its pre-migration state.
17. The pre-transfer verification of the live `.env` file's path and contents on desktop-agent (per requirement 6) was performed before the transfer took place, and its result was recorded.
18. Each of the three sibling repo clones on xps-agent (`nba-analytics-hub`, `nba-data-service`, `nba-predictor`) is checked out at the exact commit SHA recorded from the corresponding desktop-agent repo at the time of migration, and no desktop-agent checkout had uncommitted local changes at that time (or any such dirty state was flagged and resolved as a blocker before proceeding).
19. The live Docker volume names (`nba-infra_go-data`, `nba-infra_predictor-data-cache`, `nba-infra_predictor-artifacts`) and container names (`nba-infra-api-1`, `nba-infra-go-feed-1`, `nba-infra-predictor-1`) on desktop-agent were verified against actual host state (not assumed) before use elsewhere in this migration, and the verification result was recorded.
