# Tasks: nba-infra Desktop-Agent-to-XPS-Agent Migration

Generated from: docs/nba-infra-xps-agent-migration/ on 2026-08-07

## Status legend
- [ ] pending
- [>] in progress
- [x] done
- [!] blocked

## Tasks

### Task 1: Create nba-app service user and directory on xps-agent
**Status**: [x] done
**Depends on**: none
**Notes**: `nba-app` created (uid 993, docker group joined), `/opt/docker/nba-app` owned correctly, Docker confirmed functional.

### Task 2: Clone four repos to xps-agent
**Status**: [x] done
**Depends on**: Task 1
**Notes**: All four cloned. **Gap found and fixed live**: this migration's own steps.md never carried through the commit-pinning safety net that requirements.md/plan.md formally require (an orchestration gap on my part during spec-challenge — added to requirements/plan but not propagated to the executable step). Fixed live instead of re-running spec-challenge: captured desktop-agent's exact HEAD SHA for all three sibling repos (all clean, no dirty state), pinned xps-agent's clones to those exact SHAs via `git checkout <sha>`. **Second, more serious gap found and fixed**: `docker-compose.desktop.yml` is untracked in nba-infra's git history on desktop-agent (`git status` shows `?? docker-compose.desktop.yml`) — a plain `git clone` does NOT include it. Without this fix, Step 11 (`docker compose up -d -f docker-compose.desktop.yml`) would have failed outright, file not found. Copied byte-for-byte via direct SSH pipe (not a secret, safe for direct copy) and diff-verified identical.

### Task 3: Verify no out-of-scope changes
**Status**: [x] done
**Depends on**: Task 2
**Notes**: Prod/compose files clean, all three sibling repos clean. Attribution grep matched `.gitignore` — false positive, the file just excludes `CLAUDE.md` (the filename convention) from tracking, not an attribution mention. No real violation.

### Task 4: Stop desktop-agent containers for consistent volume snapshot
**Status**: [x] done
**Depends on**: none
**Notes**: MIGRATION_TAG=20260807-1254 (used for the rest of this migration). All three confirmed stopped.

### Task 5: Export volumes from desktop-agent via tar and checksum
**Status**: [x] done
**Depends on**: Task 4
**Notes**: Non-empty sanity check passed for all three (5, 2, 3 files). Exported, checksummed cleanly.

### Task 6: Transfer volume tars to xps-agent and verify checksums
**Status**: [x] done
**Depends on**: Task 5
**Notes**: All three transferred and checksum-verified exact match.

### Task 7: Resume containers on desktop-agent (rollback copy)
**Status**: [x] done
**Depends on**: Task 6
**Notes**: Resumed, 3/3 running (Compose reported "Recreate" due to the explicit `-p nba-infra` flag differing from the container's original invocation shape — functionally fine, named volumes are external and untouched by container recreation). Post-resume file count on `go-data` shows 3 (down from the exported 5) — expected, `go-feed` is a live realtime-feed service actively pruning/writing its own snapshot data now that it's running again; the already-checksummed export is unaffected.

### Task 8: Create named volumes and extract tars on xps-agent
**Status**: [x] done
**Depends on**: Task 6
**Notes**: All three volumes created with exact matching names, extracted, post-extraction file counts match source exactly (5, 2, 3).

### Task 9: [OPERATOR-ONLY] Verify and transfer .env file
**Status**: [x] done
**Depends on**: Task 1
**Notes**: OPERATOR-RUN ONLY per CONVENTIONS.md secrets rule. Contains BALLDONTLIE_API_KEY. Operator confirmed done.

### Task 10: Verify .env variables on xps-agent
**Status**: [x] done
**Depends on**: Task 9
**Notes**: All 10 variables present by name. File mode 600 nba-app:nba-app. Whole-file sha256sum matches exactly between hosts (value-level correctness confirmed without ever printing contents).

### Task 11: Start containers on xps-agent
**Status**: [x] done
**Depends on**: Task 2, Task 8, Task 10
**Notes**: Three real gaps found and fixed live, none caught by spec-challenge's 7 agents or earlier investigation:
1. **`nba-app`'s `--no-create-home` breaks local image builds.** Unlike fashion-monitor (which only ever `docker load`ed pre-built images), this compose file builds images ON the host, and the build toolchain needs a writable `$HOME`. Fixed by passing `HOME=/opt/docker/nba-app` explicitly (a directory nba-app already owns) rather than creating a real home directory.
2. **`--project-directory /opt/docker/nba-app` breaks relative build-context resolution.** It changes the base directory for *all* relative path resolution in the compose file, not just the project name — `../nba-data-service` resolved to `/opt/docker/nba-data-service` (missing `nba-app/`) instead of the correct sibling path. Fixed by dropping `--project-directory` and running from inside the `nba-infra` checkout instead (`cd` wrapped inside `sudo -u nba-app bash -c '...'` so the traversal happens as the owning user).
3. **`api`'s Dockerfile needs a pre-built `dist/`** (`COPY dist .`) that `docker compose build` doesn't produce itself — per this repo's own README, that requires an `nx` build (`scripts/up.sh`) with Node/npm toolchain, which isn't installed on xps-agent and is out of scope to install for a host migration. Desktop-agent already has this pre-built (1.6M) from its original setup — copied it directly via tar-over-SSH instead (matching the pattern already established for volumes/config), diff-verified identical.
4. **`--project-directory` vs `--env-file` conflict, the most subtle one.** Dropping `--project-directory` (needed to fix #2) also broke `${BALLDONTLIE_API_KEY}` compose-level variable substitution, since Compose's implicit `.env` discovery then looks in the compose file's own directory (`nba-infra/`), not where the real `.env` actually lives (`/opt/docker/nba-app/.env`, parent dir). Fixed with the explicit `--env-file /opt/docker/nba-app/.env` flag, which is independent of directory-based discovery entirely — the correct, permanent fix rather than a workaround. **Also checked desktop-agent for the same exposure**: Step 7's earlier resume there recreated its containers too, but happened to keep `--project-directory /opt/docker/nba-app` (never needed to rebuild, so the build-context bug never surfaced there) — which incidentally made its `.env` discovery resolve correctly by accident. Confirmed via `docker inspect` that desktop-agent's real `BALLDONTLIE_API_KEY` value is intact, not blanked.

All three containers now running cleanly with correct env values (spot-checked via `docker inspect`, matches desktop-agent's real value exactly): api `[ready]` on :3000, go-feed's snapshot sync started with no errors, predictor's uvicorn running. `steps.md`'s Step 11/17 command blocks still show the old `--project-directory`-based invocation — needs a follow-up doc-sync pass before this spec is trusted for a future re-run.

### Task 12: Verify containers stable for 10 minutes
**Status**: [x] done
**Depends on**: Task 11
**Notes**: 10/10 checks passed (60s intervals), zero restarts on all three containers throughout.

### Task 13: Verify api reachable on port 3020
**Status**: [x] done
**Depends on**: Task 12
**Notes**: `curl http://xps-agent:3020/` failed to resolve — `xps-agent` is only an SSH config alias, not a real hostname (matches Scope Auditor's flagged gap). Used the real IP (10.0.0.244) instead. `/` returns 404 (expected — API-only backend, no root route) with proper Express headers confirming the server is genuinely alive. Found and used the actual health endpoint: `/health` returns 200. Resolves challenge-notes.md's open question about AC6's exact path.

### Task 14: Verify service dependencies and network connectivity
**Status**: [x] done
**Depends on**: Task 13
**Notes**: `curl` isn't installed in the api container's alpine image (Scope Auditor's flagged gap, confirmed real). Used `wget` instead (available). Both go-feed and predictor return real HTTP responses (404, same no-root-route pattern as api itself) — confirms genuine network reachability, not connection-refused. Neither has a host port mapping — internal-network-only confirmed.

### Task 15: Verify data files present in containers
**Status**: [x] done
**Depends on**: Task 12
**Notes**: All three mounts match the recorded source file counts exactly (go-data: 5/5, predictor-data-cache: 2/2, predictor-artifacts: 3/3) — confirmed from inside the running containers at the exact paths they read from, not just synced to the host. This is the direct verification of the spec's own stated highest-impact risk (silently-empty volumes) — passes clean.

### Task 16: Verify go-feed container runs as uid 0
**Status**: [x] done
**Depends on**: Task 11
**Notes**: Configured user "0", `docker exec ... id` confirms uid=0(root). Run ahead of Task 12 since it only depends on Task 11 (already done) — no dependency on the stability window.

### Task 17: Verify runtime configuration compliance
**Status**: [x] done
**Depends on**: Task 12
**Notes**: All three containers confirmed `unless-stopped`. No VPN/gluetun network attached to any container. No NBA-related systemd units or cron jobs on xps-agent — relies solely on Docker's own restart policy, matching FR14/AC15.

## Blocked / open

**All 17 tasks complete. Migration live and verified on xps-agent.** desktop-agent remains fully running as the rollback copy (untouched data, all three containers up) through the 7-day rollback window per AC14 — decommissioning it is a separate, later action, not part of this migration's scope.

Real gaps found and fixed live during execution, none caught by the 7-agent spec-challenge pass (all documented in the relevant task's Notes above, and `steps.md`'s Step 11 has been corrected to match):
- Own orchestration gap: the commit-pinning safety check landed in requirements.md/plan.md during spec-challenge but never made it into steps.md's executable Step 2 — fixed live (Task 2).
- `docker-compose.desktop.yml` is untracked in git — a plain clone doesn't include it (Task 2).
- `nba-app`'s `--no-create-home` breaks local image builds; `--project-directory` breaks both build-context path resolution and `.env` variable substitution simultaneously in ways that fight each other — resolved with `HOME=`, dropping `--project-directory`, and explicit `--env-file` (Task 11).
- `api`'s Dockerfile needs a prebuilt `dist/` that isn't producible on xps-agent without installing a full Node/Nx toolchain — copied the existing build output from desktop-agent instead (Task 11).
- `xps-agent` is only an SSH config alias, not a resolvable hostname for plain HTTP clients (Task 13); `curl` isn't installed in the api container's image, used `wget` instead (Task 14).

Documentation synced to reflect the live cutover: `DEPLOYMENT.md` (public) and `docs-internal/DEPLOYMENT.md` (internal, with real host/IP specifics) both got a new "Desktop-tier (internal, non-production)" section, per this repo's own change-policy requirement to keep docs aligned with process changes.
