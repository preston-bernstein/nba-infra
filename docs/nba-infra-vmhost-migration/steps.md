# Steps: nba-infra Desktop-Agent-to-XPS-Agent Migration

## Prerequisites

- vmhost.example.internal host is online and reachable via SSH.
- All four repositories (nba-infra, nba-analytics-hub, nba-data-service, internal-prediction-service) are confirmed public on GitHub — plain unauthenticated `git clone https://github.com/...` works; no SSH agent-forwarding (`-A`) or operator attendance is required for the clone step.
- desktop.example.internal instance (`docker compose` and three containers: `nba-infra-api-1`, `nba-infra-go-feed-1`, `nba-infra-predictor-1`) is running with consistent, backed-up data.
- Docker and Compose v2 (v5.4.0) are already installed and functional on vmhost.example.internal — a satisfied prerequisite, confirmed live; Step 1 below re-confirms it before use rather than treating it as an open risk.
- Operator has SSH access to both desktop.example.internal and vmhost.example.internal with `sudo` NOPASSWD for the `agent` user.
- Rollback window (7 days) is defined and communicated before cutover starts.

## Implementation steps

### Step 1: Create nba-app service user and directory on vmhost.example.internal
**What**: Create a system service account `nba-app` on vmhost.example.internal using an idempotent pattern (no interactive login shell, no home directory), add it to the `docker` group so later `sudo -u nba-app docker ...` commands succeed, create the `<docker-root>/nba-app/` directory owned by that account, and re-confirm Docker/Compose is functional on the host.
**Files**: None.
**Test**: `ssh vmhost.example.internal "id nba-app"` returns uid/gid and lists `docker` among the account's groups; run the step again and verify no error (idempotent). `ssh vmhost.example.internal "ls -ld <docker-root>/nba-app"` returns ownership `nba-app:nba-app` and permissions `-rwxr-xr-x` or similar. `ssh vmhost.example.internal "docker ps"` succeeds (exit 0, table header printed).
**Depends on**: none.
**Parallelizable**: No.

**Command**:
```bash
ssh vmhost.example.internal "id -u nba-app >/dev/null 2>&1 || sudo useradd --system --no-create-home --shell /usr/sbin/nologin --groups docker nba-app"
# Idempotent: ensure docker-group membership even if the account already existed without it.
ssh vmhost.example.internal "sudo usermod -aG docker nba-app"

ssh vmhost.example.internal "sudo mkdir -p <docker-root>/nba-app && sudo chown nba-app:nba-app <docker-root>/nba-app"

# Re-confirm Docker/Compose is installed and functional before relying on it in later steps.
ssh vmhost.example.internal "docker ps" || { echo "DOCKER NOT FUNCTIONAL ON XPS-AGENT"; exit 1; }
```

### Step 2: Clone four repos to vmhost.example.internal
**What**: Clone nba-infra, nba-analytics-hub, nba-data-service, and internal-prediction-service into <docker-root>/nba-app/ as the nba-app user. Repos are public on GitHub, so no authentication required.
**Files**: None.
**Test**: `ssh vmhost.example.internal "ls -la <docker-root>/nba-app/"` shows four directories: nba-infra, nba-analytics-hub, nba-data-service, internal-prediction-service. Each contains a `.git/` subdirectory.
**Depends on**: Step 1.
**Parallelizable**: Yes.

**Commands** (run sequentially or in parallel as convenient):
```bash
ssh vmhost.example.internal "sudo -u nba-app git clone https://github.com/preston-bernstein/nba-infra.git <docker-root>/nba-app/nba-infra"
ssh vmhost.example.internal "sudo -u nba-app git clone https://github.com/preston-bernstein/nba-analytics-hub.git <docker-root>/nba-app/nba-analytics-hub"
ssh vmhost.example.internal "sudo -u nba-app git clone https://github.com/preston-bernstein/nba-data-service.git <docker-root>/nba-app/nba-data-service"
ssh vmhost.example.internal "sudo -u nba-app git clone https://github.com/preston-bernstein/internal-prediction-service.git <docker-root>/nba-app/internal-prediction-service"
```

### Step 3: Verify no out-of-scope changes
**What**: A read-only check, run immediately after cloning (before any host-state changes begin), confirming the migration has not touched anything it shouldn't: production files unchanged, `docker-compose.desktop.yml` unchanged, sibling repositories show no source diff, and no AI-assistant attribution appears anywhere in the vmhost.example.internal clone's commit history or tracked files. Running this early — right after clone, before 13 more steps of host-state changes — catches an accidental repo mutation immediately instead of at the very end.
**Files**: None.
**Test**: `git status -s` on the listed production/compose files and on each sibling repo returns empty output (no changes); the attribution search returns no matches.
**Depends on**: Step 2.
**Parallelizable**: Yes.

**Commands**:
```bash
# Production and compose files must show no uncommitted changes from their repository state.
OUTPUT=$(ssh vmhost.example.internal "cd <docker-root>/nba-app/nba-infra && git status -s docker-compose.prod.yml docker-compose.desktop.yml DEPLOYMENT.md Caddyfile")
[[ -z "$OUTPUT" ]] || { echo "PRODUCTION/COMPOSE FILES HAVE UNCOMMITTED CHANGES:"; echo "$OUTPUT"; exit 1; }

# Sibling repositories must show no source-code changes from their cloned state.
for REPO in nba-analytics-hub nba-data-service internal-prediction-service; do
  REPO_OUTPUT=$(ssh vmhost.example.internal "cd <docker-root>/nba-app/${REPO} && git status -s")
  [[ -z "$REPO_OUTPUT" ]] || { echo "${REPO} HAS UNCOMMITTED CHANGES:"; echo "$REPO_OUTPUT"; exit 1; }
done

# No AI-assistant attribution in commit history or tracked files.
ATTRIBUTION_HITS=$(ssh vmhost.example.internal "cd <docker-root>/nba-app/nba-infra && (git log -i --all --grep='claude\|anthropic' --oneline; git grep -il 'claude\|anthropic' -- . 2>/dev/null)")
[[ -z "$ATTRIBUTION_HITS" ]] || { echo "AI-ASSISTANT ATTRIBUTION FOUND:"; echo "$ATTRIBUTION_HITS"; exit 1; }

echo "No out-of-scope changes detected: production/compose files clean, sibling repos clean, no AI attribution found."
```

### Step 4: Stop desktop.example.internal containers for consistent volume snapshot
**What**: Stop the three running containers (api, go-feed, predictor) on desktop.example.internal to ensure a clean tar snapshot without torn writes mid-export, and positively confirm all three actually reached a stopped state (not just that the `stop` command was issued). Also establishes a per-run scoped tmp directory (`/tmp/nba-migrate-<tag>/`) used by Steps 4–8 instead of bare `/tmp/...` paths.
**Files**: None.
**Test**: `ssh desktop.example.internal "cd <docker-root>/nba-app/nba-infra && sudo -u nba-app docker compose -p nba-infra -f docker-compose.desktop.yml --project-directory <docker-root>/nba-app ps --status running -q"` returns empty output (nothing running).
**Depends on**: none.
**Parallelizable**: No (must happen before export; containers stay stopped until the transfer + checksum verification in Step 6 succeeds).

**Command**:
```bash
# Define a per-run scoped tmp directory tag; reuse this exact value in Steps 5-8 and Step 15 below.
export MIGRATION_TAG=$(date +%Y%m%d-%H%M)
echo "MIGRATION_TAG=${MIGRATION_TAG}  (reuse this exact value in every remaining step of this migration run)"
mkdir -p /tmp/nba-migrate-${MIGRATION_TAG}
ssh desktop.example.internal "mkdir -p /tmp/nba-migrate-${MIGRATION_TAG}" || { echo "FAILED TO CREATE SCOPED TMP DIR ON DESKTOP-AGENT"; exit 1; }

ssh desktop.example.internal "cd <docker-root>/nba-app/nba-infra && sudo -u nba-app docker compose -p nba-infra -f docker-compose.desktop.yml --project-directory <docker-root>/nba-app stop" \
  || { echo "STOP COMMAND FAILED"; exit 1; }

# Confirm all three containers actually reached a stopped state.
RUNNING=$(ssh desktop.example.internal "sudo -u nba-app docker compose -p nba-infra -f <docker-root>/nba-app/nba-infra/docker-compose.desktop.yml --project-directory <docker-root>/nba-app ps --status running -q") \
  || { echo "FAILED TO CHECK CONTAINER STATE"; exit 1; }
[[ -z "$RUNNING" ]] || { echo "CONTAINERS STILL RUNNING AFTER STOP: $RUNNING"; exit 1; }
echo "All three containers confirmed stopped."
```

### Step 5: Export volumes from desktop.example.internal via tar and checksum
**What**: Before tarring, sanity-check each source volume is non-empty (catches a wrong volume name or an unexpectedly-empty source before it gets checksummed as "correctly" empty), record its file count for later comparison, then export the three named volumes (nba-infra_go-data, nba-infra_predictor-data-cache, nba-infra_predictor-artifacts) to `/tmp/nba-migrate-${MIGRATION_TAG}/*.tar.gz` on desktop.example.internal and generate checksums, saved locally for later comparison.
**Files**: None.
**Test**: `ssh desktop.example.internal "ls -lah /tmp/nba-migrate-${MIGRATION_TAG}/*.tar.gz"` lists three tar files. `cat /tmp/nba-migrate-${MIGRATION_TAG}/nba-source-checksums.txt` (local) shows three sha256 checksums. `cat /tmp/nba-migrate-${MIGRATION_TAG}/source-filecounts.txt` (local) shows three non-zero file counts, one per volume.
**Depends on**: Step 4.
**Parallelizable**: No.

**Commands**:
```bash
for VOL in nba-infra_go-data nba-infra_predictor-data-cache nba-infra_predictor-artifacts; do
  # Pre-tar sanity check: source volume must be non-empty before we trust a checksum on it.
  COUNT=$(ssh desktop.example.internal "sudo docker run --rm -v ${VOL}:/from alpine:3.19 find /from -mindepth 1 | wc -l") \
    || { echo "FAILED TO INSPECT VOLUME: ${VOL}"; exit 1; }
  [[ "$COUNT" -gt 0 ]] || { echo "SOURCE VOLUME IS EMPTY (wrong name or already-lost data): ${VOL}"; exit 1; }
  echo "${VOL} ${COUNT}" >> /tmp/nba-migrate-${MIGRATION_TAG}/source-filecounts.txt

  # Export via throwaway alpine container.
  ssh desktop.example.internal "sudo docker run --rm -v ${VOL}:/from -v /tmp/nba-migrate-${MIGRATION_TAG}:/to alpine:3.19 tar czf /to/${VOL}.tar.gz -C /from ." \
    || { echo "TAR EXPORT FAILED: ${VOL}"; exit 1; }

  ssh desktop.example.internal "sudo sha256sum /tmp/nba-migrate-${MIGRATION_TAG}/${VOL}.tar.gz" >> /tmp/nba-migrate-${MIGRATION_TAG}/nba-source-checksums.txt \
    || { echo "CHECKSUM FAILED: ${VOL}"; exit 1; }
done
echo "All three volumes exported, sanity-checked, and checksummed on desktop.example.internal."
```

### Step 6: Transfer volume tars to vmhost.example.internal and verify checksums
**What**: Pipe each tar file from desktop.example.internal to vmhost.example.internal via SSH, landing in `/tmp/nba-migrate-${MIGRATION_TAG}/*.tar.gz.tmp` (temporary name). After all three are transferred, checksum each `.tmp` file on vmhost.example.internal and verify it matches the source checksum using literal (non-regex) matching, since filenames contain dots. Halt on any mismatch. desktop.example.internal's containers remain stopped until this step succeeds — see Step 7.
**Files**: None.
**Test**: `ssh vmhost.example.internal "ls -lah /tmp/nba-migrate-${MIGRATION_TAG}/*.tar.gz.tmp"` shows no `.tmp` files (all renamed to final `.tar.gz` below). `ssh vmhost.example.internal "ls -lah /tmp/nba-migrate-${MIGRATION_TAG}/*.tar.gz"` lists three verified tars. Checksum output confirms all three match source.
**Depends on**: Step 5.
**Parallelizable**: No.

**Commands**:
```bash
ssh vmhost.example.internal "mkdir -p /tmp/nba-migrate-${MIGRATION_TAG}" || { echo "FAILED TO CREATE SCOPED TMP DIR ON XPS-AGENT"; exit 1; }

# Transfer each tar via ssh pipe to .tmp file on vmhost.example.internal.
for VOL in nba-infra_go-data nba-infra_predictor-data-cache nba-infra_predictor-artifacts; do
  set -o pipefail
  ssh desktop.example.internal "sudo cat /tmp/nba-migrate-${MIGRATION_TAG}/${VOL}.tar.gz" \
    | ssh vmhost.example.internal "sudo tee /tmp/nba-migrate-${MIGRATION_TAG}/${VOL}.tar.gz.tmp >/dev/null"
  [[ ${PIPESTATUS[0]} -eq 0 && ${PIPESTATUS[1]} -eq 0 ]] || { echo "TRANSFER FAILED: ${VOL}"; exit 1; }
done

# Checksum verify on vmhost.example.internal using literal (-F) matching; halt on mismatch.
for VOL in nba-infra_go-data nba-infra_predictor-data-cache nba-infra_predictor-artifacts; do
  SRC=$(grep -F "${VOL}.tar.gz" /tmp/nba-migrate-${MIGRATION_TAG}/nba-source-checksums.txt | awk '{print $1}')
  [[ -n "$SRC" ]] || { echo "NO SOURCE CHECKSUM RECORDED FOR: ${VOL}"; exit 1; }
  DST=$(ssh vmhost.example.internal "sudo sha256sum /tmp/nba-migrate-${MIGRATION_TAG}/${VOL}.tar.gz.tmp" | awk '{print $1}') \
    || { echo "FAILED TO CHECKSUM ON XPS-AGENT: ${VOL}"; exit 1; }
  [[ "$SRC" == "$DST" ]] || { echo "CHECKSUM MISMATCH: ${VOL}"; exit 1; }
  ssh vmhost.example.internal "sudo mv /tmp/nba-migrate-${MIGRATION_TAG}/${VOL}.tar.gz.tmp /tmp/nba-migrate-${MIGRATION_TAG}/${VOL}.tar.gz" \
    || { echo "RENAME FAILED: ${VOL}"; exit 1; }
done
echo "All three volumes transferred and checksum-verified on vmhost.example.internal."
```

### Step 7: Resume containers on desktop.example.internal (rollback copy)
**What**: Only now — after the transfer and checksum verification in Step 6 have succeeded on vmhost.example.internal — restart the three containers on desktop.example.internal to maintain the live rollback instance through the 7-day rollback window (AC14). Resuming any earlier (immediately after export, before the transfer completes) would risk desktop.example.internal writing new data during the multi-minute transfer, making the already-checksummed vmhost.example.internal snapshot stale by the time it lands. This intentionally means slightly longer desktop.example.internal downtime, acceptable for this low-stakes, sub-20KB, internal-only instance, in exchange for a guaranteed-consistent snapshot. Desktop-agent data and volumes are never touched after this point.
**Files**: None.
**Test**: `ssh desktop.example.internal "cd <docker-root>/nba-app/nba-infra && sudo -u nba-app docker compose -p nba-infra -f docker-compose.desktop.yml --project-directory <docker-root>/nba-app ps"` shows all three containers in `Up` or `running` state.
**Depends on**: Step 6.
**Parallelizable**: No (must not run until Step 6's transfer and checksum verification succeed — resuming earlier risks a stale, inconsistent snapshot).

**Command**:
```bash
ssh desktop.example.internal "cd <docker-root>/nba-app/nba-infra && sudo -u nba-app docker compose -p nba-infra -f docker-compose.desktop.yml --project-directory <docker-root>/nba-app up -d" \
  || { echo "RESUME FAILED"; exit 1; }

RUNNING_COUNT=$(ssh desktop.example.internal "sudo -u nba-app docker compose -p nba-infra -f <docker-root>/nba-app/nba-infra/docker-compose.desktop.yml --project-directory <docker-root>/nba-app ps --status running -q | wc -l") \
  || { echo "FAILED TO CHECK RESUMED STATE"; exit 1; }
[[ "$RUNNING_COUNT" -eq 3 ]] || { echo "NOT ALL CONTAINERS RESUMED (found ${RUNNING_COUNT}/3)"; exit 1; }
echo "desktop.example.internal containers resumed; rollback instance live."
```

### Step 8: Create named volumes and extract tars on vmhost.example.internal
**What**: Create three empty named volumes on vmhost.example.internal with exact names (nba-infra_go-data, nba-infra_predictor-data-cache, nba-infra_predictor-artifacts), extract the tar contents into them via throwaway alpine containers, and verify the extraction wasn't truncated or corrupted by comparing the extracted file count against the source count recorded in Step 5. This must happen before the first `docker compose up -d`, so Compose attaches to pre-populated volumes instead of creating empty ones.
**Files**: None.
**Test**: `ssh vmhost.example.internal "sudo docker volume ls"` lists the three volumes by exact name. `ssh vmhost.example.internal "sudo docker volume inspect nba-infra_go-data"` returns a valid JSON volume object. Extracted file counts match the recorded source counts for all three volumes.
**Depends on**: Step 6.
**Parallelizable**: No.

**Commands**:
```bash
for VOL in nba-infra_go-data nba-infra_predictor-data-cache nba-infra_predictor-artifacts; do
  ssh vmhost.example.internal "sudo docker volume create ${VOL}" || { echo "VOLUME CREATE FAILED: ${VOL}"; exit 1; }
  ssh vmhost.example.internal "sudo docker run --rm -v ${VOL}:/to -v /tmp/nba-migrate-${MIGRATION_TAG}:/from alpine:3.19 tar xzf /from/${VOL}.tar.gz -C /to" \
    || { echo "EXTRACT FAILED: ${VOL}"; exit 1; }

  # Post-extraction verification: confirm the extraction wasn't truncated or corrupted.
  EXPECTED=$(grep -F "${VOL}" /tmp/nba-migrate-${MIGRATION_TAG}/source-filecounts.txt | awk '{print $2}')
  [[ -n "$EXPECTED" ]] || { echo "NO RECORDED SOURCE FILE COUNT FOR: ${VOL}"; exit 1; }
  ACTUAL=$(ssh vmhost.example.internal "sudo docker run --rm -v ${VOL}:/to alpine:3.19 find /to -mindepth 1 | wc -l") \
    || { echo "FAILED TO COUNT EXTRACTED FILES: ${VOL}"; exit 1; }
  [[ "$ACTUAL" -eq "$EXPECTED" ]] || { echo "EXTRACTED FILE COUNT MISMATCH: ${VOL} (expected ${EXPECTED}, got ${ACTUAL})"; exit 1; }
done
echo "All three volumes created, extracted, and verified on vmhost.example.internal."
```

### Step 9: [OPERATOR-ONLY] Verify and transfer .env file
**What**: Confirm the live location and contents of the .env file on desktop.example.internal (FR6: verify against actual running state, not a stale doc), then transfer it to vmhost.example.internal via a single direct SSH-to-SSH pipe that the operator runs once — the secret value (BALLDONTLIE_API_KEY and related) is never displayed, copy-pasted between panes, or otherwise exposed to a session log or agent transcript.
**Files**: None.
**Test**: `.env` file exists at `<docker-root>/nba-app/.env` on vmhost.example.internal with permissions `600`; `ssh vmhost.example.internal "sudo grep -c '^BALLDONTLIE_API_KEY=' <docker-root>/nba-app/.env"` returns `1` (variable present). All ~10 expected variable names are confirmed present by name-only grep (values never checked by agent).
**Depends on**: Step 1.
**Parallelizable**: No (must be operator-attended; not scriptable by an agent).

**Operator instructions** (run by hand at the terminal, not via tool):
1. Confirm the live .env on desktop.example.internal:
   ```bash
   ssh desktop.example.internal "sudo test -f <docker-root>/nba-app/.env && sudo wc -l <docker-root>/nba-app/.env"
   ```
   Expect output: `~10 <docker-root>/nba-app/.env` (exact line count confirms the file exists and matches expected structure).

2. Transfer the file directly, host to host, in a single pipe — the value never lands on the operator's screen or clipboard:
   ```bash
   ssh desktop.example.internal "sudo cat <docker-root>/nba-app/.env" | ssh vmhost.example.internal "sudo -u nba-app tee <docker-root>/nba-app/.env >/dev/null"
   ```

3. Fix permissions:
   ```bash
   ssh vmhost.example.internal "sudo chmod 600 <docker-root>/nba-app/.env"
   ```

4. Do not run any `cat`, `curl`, `echo`, or other command that prints the .env file's contents in any agent tool or transcript.

### Step 10: Verify .env variables on vmhost.example.internal
**What**: Confirm all ~10 expected environment variable names are present in the .env file on vmhost.example.internal, by name only (values never printed by agent), and additionally compare a whole-file sha256sum between desktop.example.internal and vmhost.example.internal to catch a transcription error that preserves variable count/names but corrupts a value — the hash comparison never prints file contents.
**Files**: None.
**Test**: Each variable name found in the file via `grep -c '^<VAR>='`. Expected count: 10 total, 1 for each variable. Whole-file sha256sum matches between hosts.
**Depends on**: Step 9.
**Parallelizable**: No.

**Commands**:
```bash
for VAR in BALLDONTLIE_API_KEY NODE_ENV API_PORT GAMES_SERVICE_URL PREDICTOR_SERVICE_URL GO_FEED_PORT PROVIDER BALLDONTLIE_BASE_URL BALLDONTLIE_TIMEZONE PREDICTOR_PORT; do
  COUNT=$(ssh vmhost.example.internal "sudo grep -c '^${VAR}=' <docker-root>/nba-app/.env")
  [[ "$COUNT" -eq 1 ]] || { echo "MISSING OR DUPLICATE: ${VAR} (found ${COUNT}, expected 1)"; exit 1; }
done
echo "All 10 variables present in .env on vmhost.example.internal."

# Value-level check: whole-file hash comparison (never prints contents).
SRC_HASH=$(ssh desktop.example.internal "sudo sha256sum <docker-root>/nba-app/.env" | awk '{print $1}') || { echo "FAILED TO HASH SOURCE .env"; exit 1; }
DST_HASH=$(ssh vmhost.example.internal "sudo sha256sum <docker-root>/nba-app/.env" | awk '{print $1}') || { echo "FAILED TO HASH DEST .env"; exit 1; }
[[ "$SRC_HASH" == "$DST_HASH" ]] || { echo ".env FILE HASH MISMATCH — value-level corruption suspected"; exit 1; }
echo ".env whole-file hash matches between desktop.example.internal and vmhost.example.internal."
```

### Step 11: Start containers on vmhost.example.internal
**What**: Invoke `docker compose` from the nba-infra checkout on vmhost.example.internal with the same command shape as desktop.example.internal, bringing up api, go-feed, and predictor in detached mode. Compose will attach to the three pre-populated named volumes and use the .env file for runtime configuration.
**Files**: None.
**Test**: `ssh vmhost.example.internal "cd <docker-root>/nba-app/nba-infra && sudo -u nba-app docker compose -p nba-infra -f docker-compose.desktop.yml --project-directory <docker-root>/nba-app ps"` lists three containers (api, go-feed, predictor) with status `Up` or `running`.
**Depends on**: Steps 2, 8, and 10.
**Parallelizable**: No.

**Command**:
```bash
ssh vmhost.example.internal "cd <docker-root>/nba-app/nba-infra && sudo -u nba-app docker compose -p nba-infra -f docker-compose.desktop.yml --project-directory <docker-root>/nba-app up -d"
```

### Step 12: Verify containers stable for 10 minutes
**What**: Poll all three containers every 60 seconds across a full 10-minute window and confirm none exit the running state or accumulate a restart, per FR16 / AC9. Halts immediately with a clear failure message on the first check that detects a problem, rather than sleeping once and declaring victory.
**Files**: None.
**Test**: Over 10 checks spaced 60 seconds apart, `docker inspect -f '{{.State.Status}}'` reports `running` and `{{.RestartCount}}` stays equal to the baseline captured right after startup, for all three containers, every time.
**Depends on**: Step 11.
**Parallelizable**: No.

**Commands**:
```bash
PROJECT_NAME=nba-infra
CONTAINERS=(api go-feed predictor)
declare -A BASELINE_RESTARTS

# Capture baseline restart counts right after startup.
for C in "${CONTAINERS[@]}"; do
  BASELINE_RESTARTS[$C]=$(ssh vmhost.example.internal "sudo docker inspect ${PROJECT_NAME}-${C}-1 -f '{{.RestartCount}}'") \
    || { echo "FAILED TO INSPECT: ${C}"; exit 1; }
done

# Poll every 60 seconds for 10 minutes (10 checks total).
for i in $(seq 1 10); do
  sleep 60
  for C in "${CONTAINERS[@]}"; do
    STATE=$(ssh vmhost.example.internal "sudo docker inspect ${PROJECT_NAME}-${C}-1 -f '{{.State.Status}}'") \
      || { echo "FAILED TO INSPECT STATE AT CHECK ${i}: ${C}"; exit 1; }
    [[ "$STATE" == "running" ]] || { echo "CONTAINER NOT RUNNING AT CHECK ${i}/10: ${C} (state: ${STATE})"; exit 1; }

    RESTARTS=$(ssh vmhost.example.internal "sudo docker inspect ${PROJECT_NAME}-${C}-1 -f '{{.RestartCount}}'") \
      || { echo "FAILED TO INSPECT RESTARTS AT CHECK ${i}: ${C}"; exit 1; }
    [[ "$RESTARTS" -eq "${BASELINE_RESTARTS[$C]}" ]] || { echo "RESTART DETECTED AT CHECK ${i}/10: ${C} (baseline ${BASELINE_RESTARTS[$C]}, now ${RESTARTS})"; exit 1; }
  done
  echo "Check ${i}/10 passed (elapsed ${i} min)."
done

echo "All containers stable for the full 10-minute window."
```

### Step 13: Verify api reachable on port 3020
**What**: Confirm the api service responds on vmhost.example.internal host port 3020 (mapped to container port 3000), matching FR11 / AC6. A basic health or API endpoint call is sufficient.
**Files**: None.
**Test**: `curl -s http://vmhost.example.internal:3020/` or similar endpoint returns an HTTP response (not connection refused or timeout). Check response code (200 or similar), not specific payload.
**Depends on**: Step 12.
**Parallelizable**: No.

**Command**:
```bash
# From the operator's machine or a test runner with network reach to vmhost.example.internal:3020.
curl -v http://vmhost.example.internal:3020/ 2>&1 | head -20
# Expect: HTTP/1.x 200 or similar, not "Connection refused" or timeout.
```

### Step 14: Verify service dependencies and network connectivity
**What**: Confirm api reaches go-feed and predictor over the Docker-managed internal network at their actual confirmed ports (go-feed listens on 4000 internally, predictor on 5000), and confirm neither go-feed nor predictor has a host port mapping — they should be reachable only inside the Docker network, per FR12 / AC7.
**Files**: None.
**Test**: Exec into api container reaches `http://go-feed:4000/` and `http://predictor:5000/` with a non-error HTTP status. `docker port` shows no mapping for either go-feed or predictor.
**Depends on**: Step 13.
**Parallelizable**: No.

**Commands**:
```bash
# Exec into api container and test internal network reach to go-feed and predictor at their real ports.
ssh vmhost.example.internal "sudo docker exec nba-infra-api-1 curl -s -o /dev/null -w '%{http_code}' http://go-feed:4000/"
ssh vmhost.example.internal "sudo docker exec nba-infra-api-1 curl -s -o /dev/null -w '%{http_code}' http://predictor:5000/"
# Expect: both return "200" or similar (not "000" for connection refused).

# Confirm go-feed and predictor have NO host port mapping (internal-network-only reachability).
for SVC in go-feed predictor; do
  PORTS=$(ssh vmhost.example.internal "sudo docker port nba-infra-${SVC}-1")
  [[ -z "$PORTS" ]] || { echo "UNEXPECTED HOST PORT MAPPING ON ${SVC}: ${PORTS}"; exit 1; }
done
echo "go-feed and predictor confirmed internal-network-only (no host port mapping)."
```

### Step 15: Verify data files present in containers
**What**: Exec into each container and confirm expected config and data files exist at the paths the container actually reads from (not just confirmed synced to the host), and that the file count matches what was recorded from the source volume during Step 5 — not merely that a listing command exited 0, which is also true for an empty directory. Spot-check go-feed's `/app/data` and predictor's `/work/data_cache` and `/work/artifacts`, per FR17 / AC10.
**Files**: None.
**Test**: For each mount, the file count found inside the running container is greater than zero and equal to the count recorded for the corresponding source volume in `/tmp/nba-migrate-${MIGRATION_TAG}/source-filecounts.txt`.
**Depends on**: Step 12.
**Parallelizable**: No.

**Commands**:
```bash
# Reuse the MIGRATION_TAG value set in Step 4 (export MIGRATION_TAG=<value> again if this runs in a new shell).
declare -A MOUNT_MAP=(
  ["nba-infra_go-data"]="nba-infra-go-feed-1:/app/data"
  ["nba-infra_predictor-data-cache"]="nba-infra-predictor-1:/work/data_cache"
  ["nba-infra_predictor-artifacts"]="nba-infra-predictor-1:/work/artifacts"
)

for VOL in "${!MOUNT_MAP[@]}"; do
  CONTAINER="${MOUNT_MAP[$VOL]%%:*}"
  PATH_IN_CONTAINER="${MOUNT_MAP[$VOL]#*:}"

  EXPECTED=$(grep -F "${VOL}" /tmp/nba-migrate-${MIGRATION_TAG}/source-filecounts.txt | awk '{print $2}')
  [[ -n "$EXPECTED" ]] || { echo "NO RECORDED SOURCE COUNT FOR: ${VOL}"; exit 1; }

  ACTUAL=$(ssh vmhost.example.internal "sudo docker exec ${CONTAINER} find ${PATH_IN_CONTAINER} -mindepth 1 | wc -l") \
    || { echo "FAILED TO COUNT FILES IN CONTAINER: ${CONTAINER}${PATH_IN_CONTAINER}"; exit 1; }
  [[ "$ACTUAL" -gt 0 ]] || { echo "DIRECTORY EMPTY INSIDE CONTAINER (silent data loss): ${CONTAINER}${PATH_IN_CONTAINER}"; exit 1; }
  [[ "$ACTUAL" -eq "$EXPECTED" ]] || { echo "FILE COUNT MISMATCH: ${CONTAINER}${PATH_IN_CONTAINER} (expected ${EXPECTED}, got ${ACTUAL})"; exit 1; }
done

echo "All data files verified present inside containers; counts match source volumes."
```

### Step 16: Verify go-feed container runs as uid 0
**What**: Confirm go-feed container on vmhost.example.internal runs under uid 0 (root), required for volume write permissions and matching desktop.example.internal, per FR13 / AC8.
**Files**: None.
**Test**: `ssh vmhost.example.internal "sudo docker inspect nba-infra-go-feed-1 -f '{{.Config.User}}'"` returns empty string or "0"; `ssh vmhost.example.internal "sudo docker exec nba-infra-go-feed-1 id"` shows `uid=0`.
**Depends on**: Step 11.
**Parallelizable**: No.

**Commands**:
```bash
# Check the container's configured user (should be empty or "0" for root).
USER=$(ssh vmhost.example.internal "sudo docker inspect nba-infra-go-feed-1 -f '{{.Config.User}}'")
if [[ -n "$USER" && "$USER" != "0" ]]; then
  echo "GO-FEED CONFIGURED USER IS NOT ROOT: $USER"; exit 1
fi

# Verify the running process is actually uid 0.
ssh vmhost.example.internal "sudo docker exec nba-infra-go-feed-1 id | grep -q 'uid=0'" || { echo "GO-FEED NOT RUNNING AS UID 0"; exit 1; }

echo "go-feed verified running as uid 0."
```

### Step 17: Verify runtime configuration compliance
**What**: Confirm each of the three containers on vmhost.example.internal is actually governed by the `restart: unless-stopped` policy (not just declared in the compose file), that no VPN/egress-tunnel network (e.g. a `gluetun`-style attachment) is attached to any of them, and that no systemd unit, cron job, or wrapper script was separately added to manage this instance — it relies solely on Docker's restart policy, not host-level scheduling, per FR14 / AC15.
**Files**: None.
**Test**: `docker inspect --format '{{.HostConfig.RestartPolicy.Name}}'` returns `unless-stopped` for all three containers; `docker inspect --format '{{json .NetworkSettings.Networks}}'` shows only the expected compose-managed network for all three; `systemctl list-units` and `crontab -l` show no NBA-related entries.
**Depends on**: Step 12.
**Parallelizable**: Yes.

**Commands**:
```bash
# Restart policy check.
for CONTAINER in nba-infra-api-1 nba-infra-go-feed-1 nba-infra-predictor-1; do
  POLICY=$(ssh vmhost.example.internal "sudo docker inspect ${CONTAINER} -f '{{.HostConfig.RestartPolicy.Name}}'") \
    || { echo "FAILED TO INSPECT RESTART POLICY: ${CONTAINER}"; exit 1; }
  [[ "$POLICY" == "unless-stopped" ]] || { echo "RESTART POLICY NOT unless-stopped: ${CONTAINER} (found: ${POLICY})"; exit 1; }
done
echo "Restart policy confirmed unless-stopped on all three containers."

# Network check: confirm no VPN/egress-tunnel network attachment.
for CONTAINER in nba-infra-api-1 nba-infra-go-feed-1 nba-infra-predictor-1; do
  NETWORKS=$(ssh vmhost.example.internal "sudo docker inspect ${CONTAINER} -f '{{json .NetworkSettings.Networks}}'") \
    || { echo "FAILED TO INSPECT NETWORKS: ${CONTAINER}"; exit 1; }
  echo "$NETWORKS" | grep -qi "gluetun" && { echo "VPN/EGRESS-TUNNEL NETWORK DETECTED ON: ${CONTAINER}"; exit 1; }
done
echo "No VPN/egress-tunnel network attached to any container."

# No systemd unit, cron job, or wrapper script added to manage this instance.
SYSTEMD_UNITS=$(ssh vmhost.example.internal "systemctl list-units --type=service 2>/dev/null | grep -i nba" || echo "")
[[ -z "$SYSTEMD_UNITS" ]] || { echo "NBA SYSTEMD UNITS FOUND:"; echo "$SYSTEMD_UNITS"; exit 1; }

CRON_JOBS=$(ssh vmhost.example.internal "sudo crontab -l 2>/dev/null | grep -i nba" || echo "")
[[ -z "$CRON_JOBS" ]] || { echo "NBA CRON JOBS FOUND:"; echo "$CRON_JOBS"; exit 1; }

echo "Runtime configuration compliant: restart policy correct, no VPN network attached, no host-level scheduling added."
```

## Rollback plan

- **Steps 1–2 (user, directory, repos)**: If any fails before volume migration begins, delete the vmhost.example.internal directories and re-run from Step 1; no data loss (desktop.example.internal untouched).
- **Step 3 (out-of-scope check)**: If this step finds unexpected diffs in production files, `docker-compose.desktop.yml`, or sibling repos, the remediation is to `git checkout`/`git restore` the affected file(s) in the vmhost.example.internal clone back to their pre-migration (last-committed) state and re-run the check. This is not a data-loss risk — purely a repo-state fix.
- **Steps 4–5 (desktop.example.internal stop + export)**: If a failure occurs here — before any transfer has been attempted — fix the issue and retry from Step 4. desktop.example.internal remains stopped (not yet resumed, per the reordered sequence) with zero data-loss risk, since no volumes have been touched.
- **Steps 6–8 (transfer, resume, volume create+extract)**: If a failure occurs anywhere in this range — including an vmhost.example.internal-only failure such as a checksum mismatch or a volume-create/extract error — retry starting from Step 6 only. The desktop.example.internal tar exports and checksums produced in Step 5 remain valid and do not need to be regenerated; there is no need to repeat Steps 4–5 (re-stopping and re-exporting desktop.example.internal) for a failure that is purely on the vmhost.example.internal side.
- **Steps 9–10 (.env)**: If .env contents are incorrect after transfer, re-run Step 9 (operator re-runs the direct SSH-to-SSH pipe).
- **Steps 11–17 (verification)**: If container startup or verification fails, stop containers on vmhost.example.internal (`ssh vmhost.example.internal "cd <docker-root>/nba-app/nba-infra && sudo -u nba-app docker compose -p nba-infra -f docker-compose.desktop.yml --project-directory <docker-root>/nba-app stop"`), review logs, fix the issue, and re-run from Step 11. Desktop-agent remains the live instance until this step completes successfully.
- **Full rollback** (before end of 7-day window): Remain on desktop.example.internal as the live instance. Stop the vmhost.example.internal containers BEFORE removing any state underneath them, then remove the directory, volumes, and service account:
  ```bash
  ssh vmhost.example.internal "cd <docker-root>/nba-app/nba-infra && sudo -u nba-app docker compose -p nba-infra -f docker-compose.desktop.yml --project-directory <docker-root>/nba-app stop"
  ssh vmhost.example.internal "sudo rm -rf <docker-root>/nba-app"
  ssh vmhost.example.internal "sudo docker volume rm nba-infra_go-data nba-infra_predictor-data-cache nba-infra_predictor-artifacts"
  ssh vmhost.example.internal "sudo userdel nba-app"
  ```
  Desktop-agent's containers stay running with no manual intervention.
