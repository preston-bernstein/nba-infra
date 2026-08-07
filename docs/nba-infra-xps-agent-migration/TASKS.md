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
**Status**: [ ] pending
**Depends on**: Task 1
**Notes**: OPERATOR-RUN ONLY per CONVENTIONS.md secrets rule. Contains BALLDONTLIE_API_KEY.

### Task 10: Verify .env variables on xps-agent
**Status**: [ ] pending
**Depends on**: Task 9
**Notes**:

### Task 11: Start containers on xps-agent
**Status**: [ ] pending
**Depends on**: Task 2, Task 8, Task 10
**Notes**:

### Task 12: Verify containers stable for 10 minutes
**Status**: [ ] pending
**Depends on**: Task 11
**Notes**:

### Task 13: Verify api reachable on port 3020
**Status**: [ ] pending
**Depends on**: Task 12
**Notes**:

### Task 14: Verify service dependencies and network connectivity
**Status**: [ ] pending
**Depends on**: Task 13
**Notes**:

### Task 15: Verify data files present in containers
**Status**: [ ] pending
**Depends on**: Task 12
**Notes**:

### Task 16: Verify go-feed container runs as uid 0
**Status**: [ ] pending
**Depends on**: Task 11
**Notes**:

### Task 17: Verify runtime configuration compliance
**Status**: [ ] pending
**Depends on**: Task 12
**Notes**:

## Blocked / open
(populated during implementation)
