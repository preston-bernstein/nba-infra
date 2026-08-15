# Plan: nba-infra Desktop-Agent-to-XPS-Agent Migration

## Approach

This is a host cutover, not a code change: `docker-compose.desktop.yml` stays byte-identical, and the only new artifacts are host-side state on xps-agent (an `nba-app` service user, four cloned repos — three pinned to desktop-agent's exact commit, three restored Docker volumes, one directly-piped `.env`). The three named volumes hold live container state (not source-controlled), so they must be exported from desktop-agent, checksummed, transferred, and restored into identically-named volumes on xps-agent *before* `docker compose up -d` runs — otherwise Compose silently creates empty volumes and the container reads no data, repeating the exact class of gap the fashion-monitor migration hit. Because this instance builds its three images from sibling repo source rather than pulling them, cloning `nba-analytics-hub`, `nba-data-service`, and `nba-predictor` onto xps-agent is part of this migration, not a side effect of it. Desktop-agent stays fully running and untouched through a 7-day rollback window (AC14 requires it "unstopped," not merely present) — this is a deliberate, temporary dual-live period, unlike the fashion-monitor migration which avoided one, and is scoped in the Risk areas below.

This is a personal/portfolio-adjacent instance with no reverse proxy or DNS abstraction in front of it; nothing in this investigation identified an active consumer of `desktop-agent:3020` today. This migration's scope stops at standing up a verified, working parallel copy on xps-agent — treating desktop-agent's copy as fully decommissioned (the actual cutover) is a separate, later action gated on the rollback window, not something this migration claims to complete.

## Architecture

```text
BEFORE                                              AFTER (end state)
desktop-agent (nba-app, real home dir — legacy)     xps-agent (nba-app, --no-create-home, nologin)
  /opt/docker/nba-app/                                /opt/docker/nba-app/
    nba-infra/  (docker-compose.desktop.yml)             nba-infra/          (git clone)
    nba-analytics-hub/                                   nba-analytics-hub/  (git clone, commit-pinned)
    nba-data-service/                                    nba-data-service/   (git clone, commit-pinned)
    nba-predictor/                                       nba-predictor/      (git clone, commit-pinned)
    .env  (~10 vars, incl. BALLDONTLIE_API_KEY)          .env  (operator-piped, byte-identical, hash-verified)
  containers: api :3020->3000, go-feed (uid0,           containers: api :3020->3000, go-feed (uid0,
    internal), predictor (internal)                       internal), predictor (internal)
  volumes: nba-infra_go-data,                            volumes: nba-infra_go-data,
    nba-infra_predictor-data-cache,                        nba-infra_predictor-data-cache,
    nba-infra_predictor-artifacts                          nba-infra_predictor-artifacts
  STAYS RUNNING (rollback copy, 7-day window)            NEW LIVE COPY, verified before desktop-agent
                                                            is left alone (not decommissioned this pass)
```

Data flow for the volume migration (the one genuinely novel step — see Data model for exact commands):

```text
desktop-agent volume --[tar in throwaway alpine:3.19 container]--> host /tmp/nba-migrate-<run-id>/*.tar.gz
  --[ssh pipe]--> xps-agent host /tmp/nba-migrate-<run-id>/*.tar.gz.tmp --[sha256 checksum gate]-->
  mv into place --[tar extract in throwaway alpine:3.19 container]--> xps-agent volume (pre-created, exact name)
  --[file-count re-verify]--> confirmed intact
```

**Why the volume names must match exactly:** the volume-name prefix Compose uses is the project name, and this plan pins it explicitly rather than relying on it being inferred. Every `docker compose` invocation in this plan — on both desktop-agent and xps-agent — sets `COMPOSE_PROJECT_NAME=nba-infra` as an environment variable, so the project name is a fixed value the command declares, not something derived from cwd basename, `--project-directory`, or any other implicit fallback whose exact precedence differs across Compose configurations. With `COMPOSE_PROJECT_NAME=nba-infra` pinned, Compose resolves the same volume names on both hosts regardless of working directory: `nba-infra_go-data`, `nba-infra_predictor-data-cache`, `nba-infra_predictor-artifacts`. The restore step must create volumes with those exact names, populated, *before* `docker compose up -d` runs, so Compose attaches to the restored data instead of creating fresh empty volumes with the same name.

## Data model

No relational data model. Three Docker named volumes are this instance's only persisted state:

| Volume | Mounted at (container) | Written by |
| --- | --- | --- |
| `nba-infra_go-data` | `go-feed`: `/app/data` | `go-feed` (uid 0) |
| `nba-infra_predictor-data-cache` | `predictor`: `/work/data_cache` | `predictor` |
| `nba-infra_predictor-artifacts` | `predictor`: `/work/artifacts` | `predictor` |

### Volume migration mechanism (FR4/FR5, AC3)

Combined size is under 20KB, but every byte is checksummed regardless (NFR). Stop all three containers on desktop-agent first — these are plain files, not a WAL-mode database with an online-backup API, so a live writer mid-`tar` risks a torn snapshot. Do not resume desktop-agent's containers as soon as the export completes: the transfer and checksum-verification steps that follow can take several minutes over `ssh`, and if desktop-agent resumed writing during that window, the volumes it already tarred would be stale by the time xps-agent's copy is confirmed good. Instead, desktop-agent's containers stay stopped until xps-agent's checksum gate passes; only then are they resumed (still well inside the 7-day rollback window AC14 requires). This means slightly longer desktop-agent downtime than a naive stop/tar/restart-immediately sequence, an acceptable trade for a guaranteed-consistent snapshot on a low-stakes internal instance with sub-20KB of data. Every host-touching step below runs in a per-run scoped tmp directory (`/tmp/nba-migrate-<run-id>/`) on both hosts rather than bare `/tmp`, to avoid collisions with concurrent or retried runs and keep cleanup to a single `rm -rf`, and every `ssh` invocation checks its own exit status and halts with an explicit error rather than continuing past a silent failure.

```bash
# 0. Scope this run to a dedicated tmp directory on both hosts.
RUN_ID=$(date +%Y%m%d-%H%M%S)
SRC_DIR="/tmp/nba-migrate-${RUN_ID}"
ssh desktop-agent "sudo mkdir -p ${SRC_DIR}" \
  || { echo "ERROR: failed to create ${SRC_DIR} on desktop-agent"; exit 1; }
ssh xps-agent "sudo mkdir -p ${SRC_DIR}" \
  || { echo "ERROR: failed to create ${SRC_DIR} on xps-agent"; exit 1; }

# 1. Desktop-agent: stop the three containers for a consistent snapshot.
#    COMPOSE_PROJECT_NAME is pinned explicitly (see Architecture) so the volume
#    names Compose resolves to are never left to implicit inference.
ssh desktop-agent "cd /opt/docker/nba-app/nba-infra && sudo -u nba-app \
  COMPOSE_PROJECT_NAME=nba-infra docker compose -f docker-compose.desktop.yml \
  --project-directory /opt/docker/nba-app stop" \
  || { echo "ERROR: docker compose stop failed on desktop-agent"; exit 1; }

# 2. Confirm all three containers actually reached a stopped state before tarring
#    begins — `stop` has a grace period, and a container mid-flush at tar time
#    would produce a torn snapshot even though the stop command itself exited 0.
RUNNING=$(ssh desktop-agent "cd /opt/docker/nba-app/nba-infra && sudo -u nba-app \
  COMPOSE_PROJECT_NAME=nba-infra docker compose -f docker-compose.desktop.yml \
  --project-directory /opt/docker/nba-app ps --status running -q") \
  || { echo "ERROR: could not query container state on desktop-agent"; exit 1; }
[[ -z "$RUNNING" ]] || { echo "ERROR: containers still running on desktop-agent, aborting"; exit 1; }

# 3. Desktop-agent: pre-tar sanity check — confirm each volume is non-empty before
#    it gets checksummed as "correctly" empty (catches a wrong ${VOL} name or an
#    unexpectedly-empty source before that becomes indistinguishable from success).
for VOL in nba-infra_go-data nba-infra_predictor-data-cache nba-infra_predictor-artifacts; do
  COUNT=$(ssh desktop-agent "sudo docker run --rm -v ${VOL}:/from alpine:3.19 \
    sh -c 'ls -A /from | wc -l'") \
    || { echo "ERROR: could not inspect ${VOL} on desktop-agent"; exit 1; }
  [[ "$COUNT" -gt 0 ]] || { echo "ERROR: ${VOL} is empty on desktop-agent, aborting"; exit 1; }
done

# 4. Desktop-agent: tar each volume via a throwaway pinned alpine container, then checksum.
for VOL in nba-infra_go-data nba-infra_predictor-data-cache nba-infra_predictor-artifacts; do
  ssh desktop-agent "sudo docker run --rm -v ${VOL}:/from -v ${SRC_DIR}:/to alpine:3.19 \
    tar czf /to/${VOL}.tar.gz -C /from ." \
    || { echo "ERROR: tar failed for ${VOL} on desktop-agent"; exit 1; }
  ssh desktop-agent "sudo sha256sum ${SRC_DIR}/${VOL}.tar.gz" \
    || { echo "ERROR: checksum failed for ${VOL} on desktop-agent"; exit 1; }
done > "${SRC_DIR}.source-checksums.txt"

# 5. Transfer each tar to a .tmp path on xps-agent (never write the final name directly).
#    Desktop-agent's containers stay stopped through this step and the checksum gate
#    below — see the intro paragraph above for why resuming early would stale the snapshot.
for VOL in nba-infra_go-data nba-infra_predictor-data-cache nba-infra_predictor-artifacts; do
  set -o pipefail
  ssh desktop-agent "sudo cat ${SRC_DIR}/${VOL}.tar.gz" \
    | ssh xps-agent "sudo tee ${SRC_DIR}/${VOL}.tar.gz.tmp >/dev/null"
  [[ ${PIPESTATUS[0]} -eq 0 && ${PIPESTATUS[1]} -eq 0 ]] || { echo "ERROR: transfer failed for ${VOL}"; exit 1; }
done

# 6. Checksum the .tmp file on xps-agent and diff against the source checksum (FR5, AC3)
#    using a literal string match (grep -F) — the tar filenames contain dots, and a bare
#    `grep` pattern would treat those as regex wildcards instead of literal characters.
#    Halt on any mismatch instead of moving a partial/corrupt tar into place.
for VOL in nba-infra_go-data nba-infra_predictor-data-cache nba-infra_predictor-artifacts; do
  SRC=$(grep -F "${VOL}.tar.gz" "${SRC_DIR}.source-checksums.txt" | awk '{print $1}')
  DST=$(ssh xps-agent "sudo sha256sum ${SRC_DIR}/${VOL}.tar.gz.tmp" | awk '{print $1}') \
    || { echo "ERROR: checksum failed for ${VOL} on xps-agent"; exit 1; }
  [[ "$SRC" == "$DST" ]] || { echo "ERROR: checksum mismatch for ${VOL}"; exit 1; }
  ssh xps-agent "sudo mv ${SRC_DIR}/${VOL}.tar.gz.tmp ${SRC_DIR}/${VOL}.tar.gz" \
    || { echo "ERROR: mv failed for ${VOL} on xps-agent"; exit 1; }
done

# 7. Only now — after every tar has transferred and checksummed clean — resume
#    desktop-agent's containers. Desktop-agent stays down slightly longer than a
#    naive stop/tar/restart-immediately sequence would allow, in exchange for a
#    guaranteed-consistent snapshot (AC14 still holds: desktop-agent ends this
#    sequence running, well inside the 7-day rollback window).
ssh desktop-agent "cd /opt/docker/nba-app/nba-infra && sudo -u nba-app \
  COMPOSE_PROJECT_NAME=nba-infra docker compose -f docker-compose.desktop.yml \
  --project-directory /opt/docker/nba-app up -d" \
  || { echo "ERROR: docker compose up -d failed on desktop-agent"; exit 1; }

# 8. xps-agent: create each named volume (exact final name) and extract into it,
#    BEFORE `docker compose up -d` ever runs — see Architecture for why the name must match.
for VOL in nba-infra_go-data nba-infra_predictor-data-cache nba-infra_predictor-artifacts; do
  ssh xps-agent "sudo docker volume create ${VOL}" \
    || { echo "ERROR: volume create failed for ${VOL} on xps-agent"; exit 1; }
  ssh xps-agent "sudo docker run --rm -v ${VOL}:/to -v ${SRC_DIR}:/from alpine:3.19 \
    tar xzf /from/${VOL}.tar.gz -C /to" \
    || { echo "ERROR: extract failed for ${VOL} on xps-agent"; exit 1; }
done

# 9. Post-extraction verification: a matching tar checksum only proves the transfer
#    was intact, not that extraction itself completed without truncation. Re-count
#    files inside the extracted volume and compare against the source volume's count.
for VOL in nba-infra_go-data nba-infra_predictor-data-cache nba-infra_predictor-artifacts; do
  SRC_COUNT=$(ssh desktop-agent "sudo docker run --rm -v ${VOL}:/from alpine:3.19 \
    sh -c 'find /from -type f | wc -l'") \
    || { echo "ERROR: source recount failed for ${VOL}"; exit 1; }
  DST_COUNT=$(ssh xps-agent "sudo docker run --rm -v ${VOL}:/to alpine:3.19 \
    sh -c 'find /to -type f | wc -l'") \
    || { echo "ERROR: dest recount failed for ${VOL}"; exit 1; }
  [[ "$SRC_COUNT" == "$DST_COUNT" ]] || { echo "ERROR: file count mismatch for ${VOL} (${SRC_COUNT} vs ${DST_COUNT})"; exit 1; }
done
```

**On checksum mismatch:** delete the `.tmp` file on xps-agent and retry from step 4 (a fresh `tar`) — do not retry step 5 against a possibly-partial `.tmp` file. Desktop-agent's containers remain stopped at this point (they are not resumed until step 7, after the checksum gate passes), so a retry costs only additional downtime, not risk to the source data; desktop-agent's live volumes are never touched by this sequence, only read via the throwaway `tar` container.

## API / interface contract

None. No HTTP route, CLI flag, or env var name changes. The only invocation surface that changes is *where* the existing command runs:

- `COMPOSE_PROJECT_NAME=nba-infra docker compose -f docker-compose.desktop.yml --project-directory /opt/docker/nba-app up -d`, executed as `sudo -u nba-app` from `/opt/docker/nba-app/nba-infra` on xps-agent instead of desktop-agent (FR10).
- `api` reachable at `http://xps-agent:3020` (was `http://desktop-agent:3020`) — same container port (3000), same path.

## Integration points

- No `nba-infra` repo files change. `docker-compose.desktop.yml`, `docker-compose.prod.yml`, `DEPLOYMENT.md`'s production section, and `Caddyfile` are untouched (FR18/FR19) — neither file references a hostname, so there is no stale-path doc drift to fix (confirmed by grep across the repo).
- xps-agent OS account `nba-app` (new) — idempotent creation matching the fleet's established pattern, including membership in the `docker` group so `sudo -u nba-app docker ...` commands can reach `docker.sock` (root:docker 660 by default; `sudo -u nba-app` runs as nba-app's own uid/gid, not root's, so without group membership every later Docker invocation would fail with a permission error): `id -u nba-app >/dev/null 2>&1 || sudo useradd --system --no-create-home --shell /usr/sbin/nologin -G docker nba-app` (FR1, AC1). See Technology choices for why this diverges from desktop-agent's current (legacy) real-home-dir setup.
- xps-agent `/opt/docker/nba-app/` (new) — `sudo mkdir -p /opt/docker/nba-app && sudo chown nba-app:nba-app /opt/docker/nba-app` (FR2, AC2).
- xps-agent `/opt/docker/nba-app/{nba-infra,nba-analytics-hub,nba-data-service,nba-predictor}/` (new) — four repos, all confirmed PUBLIC on GitHub (`gh repo view <repo> --json visibility` returned `PUBLIC` for all four), so cloning needs no credential, no SSH agent forwarding, and no operator attendance — it is a plain agent-runnable command: `ssh xps-agent "sudo -u nba-app git clone https://github.com/preston-bernstein/<repo>.git /opt/docker/nba-app/<repo>"` for each of the four repos (FR3, AC2). `sudo -u nba-app` works non-interactively despite the `nologin` shell — a single command via `sudo -u` execs directly, it doesn't require an interactive login shell (same pattern already proven by the fashion-monitor migration's `sudo -u fashionmonitor docker compose ...` invocations).
  For the three sibling repos that back running containers (`nba-analytics-hub`, `nba-data-service`, `nba-predictor` — not `nba-infra` itself, which has no runtime volume dependency), pin the clone to the exact commit desktop-agent is running rather than whatever the default branch's tip happens to be (extends FR3, AC2): before cloning, capture `git -C /opt/docker/nba-app/<repo> rev-parse HEAD` and `git -C /opt/docker/nba-app/<repo> status --porcelain` for each of the three checkouts on desktop-agent. If any checkout is dirty (`status --porcelain` returns output), stop and get explicit human sign-off before proceeding — per this repo's own "ask before assuming" change policy, a dirty desktop-agent checkout is a blocker, not something to silently paper over. Once each SHA is captured clean, after cloning on xps-agent run `git -C /opt/docker/nba-app/<repo> checkout <same-sha>` for each of the three repos, so the code now running against the migrated volumes matches the code that generated `predictor-data-cache`/`predictor-artifacts`' existing contents — a mismatch here would start cleanly and fail silently, the exact failure class this plan is otherwise built to prevent.
- xps-agent three named Docker volumes (new) — created and populated by the tar export/import sequence above, *before* the first `docker compose up -d` (FR4/FR5, AC3).
- xps-agent `/opt/docker/nba-app/.env` (new, host-side only, never repo-tracked) — operator-run, no agent tool call in the path (FR6/FR7/FR8/FR9, AC4). Before any transfer: `ssh desktop-agent "sudo test -f /opt/docker/nba-app/.env && sudo wc -l /opt/docker/nba-app/.env"` to confirm the live path and line count still match this document's stated facts (FR6) — do not skip this even though the live-state investigation already confirmed it, since the fashion-monitor migration's exact failure mode was trusting a document's stated path without a live re-check. The operator (not an agent) then runs a single direct SSH-to-SSH pipe, at the terminal, that never displays the secret value anywhere — not on screen, not in scrollback, not via clipboard:

  ```bash
  ssh desktop-agent "sudo cat /opt/docker/nba-app/.env" | ssh xps-agent "sudo -u nba-app tee /opt/docker/nba-app/.env >/dev/null"
  ssh xps-agent "sudo chmod 600 /opt/docker/nba-app/.env"
  ```

  This replaces a copy-from-one-pane/paste-into-another approach, which would put `BALLDONTLIE_API_KEY` on screen, in terminal scrollback, and potentially on the clipboard — the pipe above prints the value nowhere. As residual hygiene, the operator should clear terminal scrollback afterward. **No agent-run command may `cat`, `curl`, or otherwise print this file's contents at any point in this migration** — confirming presence by variable *name* only (`ssh xps-agent "sudo grep -c '^BALLDONTLIE_API_KEY=' /opt/docker/nba-app/.env"` returning `1`) is fine; printing values is not. In addition to the by-name checks for all ~10 variables, gate on a whole-file `sha256sum` computed independently on both hosts (`ssh desktop-agent "sudo sha256sum /opt/docker/nba-app/.env"` vs `ssh xps-agent "sudo sha256sum /opt/docker/nba-app/.env"`) — a hash never exposes the file's contents, but catches a transcription slip that corrupts a value while variable count and names remain intact, which the by-name check alone cannot detect.
- xps-agent `nba-infra_go-data`, `nba-infra_predictor-data-cache`, `nba-infra_predictor-artifacts` — same volume names as desktop-agent because `COMPOSE_PROJECT_NAME=nba-infra` is pinned explicitly on both hosts (see Architecture), so `docker-compose.desktop.yml`'s existing `volumes:` block needs no edit.
- `docs-internal/` (new content) — per this repo's own change policy ("update documentation when behavior changes... do not proceed without aligning docs"), add one short paragraph recording that a desktop-tier (non-production) instance of this stack now runs on xps-agent instead of desktop-agent, reachable at `:3020` internally, and is separate from the production DigitalOcean deployment. Use judgment on the most natural existing location in `docs-internal/`, or create a new small file if none fits — keep it to one paragraph, matching this repo's terse, factual documentation style. (A systemd unit and a home-infra `manifest.json` drift-audit entry for this workload were considered and rejected: `manifest.json`/`drift_audit.py` belong to the separate `home-infra` repo and track home-infra's own components, not personal apps deployed on a shared host — out of scope here.)

## Technology choices

- `COMPOSE_PROJECT_NAME=nba-infra` pinned explicitly as an environment variable on every `docker compose` invocation in this plan, rather than relying on Compose's implicit project-name derivation (cwd basename, `--project-directory`, or any other fallback) — the exact precedence between these implicit paths differs across Compose configurations, and getting it wrong produces the single highest-impact failure mode in this plan (Risk area 1). An explicit pin removes the ambiguity entirely instead of depending on which implicit rule wins.
- `alpine:3.19` (pinned, not the floating `latest` tag) + `tar` inside a throwaway `docker run --rm` container for the volume export/import — the standard mechanism for moving a named volume's contents through the host filesystem, since a named volume (unlike a bind mount) has no direct host path to `scp`. Pinning the tag avoids an unreviewed image change silently altering the tar/extract environment between the export and import halves of the same migration.
- Plain `ssh` pipes (`cat | ssh ... tee`) for both the volume tars and the `.env` file, matching the pattern already established by the fashion-monitor migration on this same host pair — no new sync tool (rsync/rclone) justified for a one-time transfer of a few KB, and a direct pipe never writes the `.env` contents to an intermediate file or the terminal.
- Plain unauthenticated `git clone` over HTTPS (`https://github.com/preston-bernstein/<repo>.git`) for the four repos, not `ssh -A` agent forwarding or a stored deploy key — all four repos are confirmed PUBLIC (`gh repo view <repo> --json visibility`), so no credential is needed at all, and this makes the clone step a plain agent-runnable command instead of requiring a live, agent-forwarding operator SSH session.
- Exact-commit pinning (`git checkout <sha>` after clone) for the three sibling repos whose containers write to migrated volumes, rather than trusting the default branch's tip — a fresh clone's tip is not guaranteed to match the exact code that generated `predictor-data-cache`/`predictor-artifacts`' existing contents, and a mismatch would be invisible at container-start time.
- `--no-create-home --shell /usr/sbin/nologin` for the `nba-app` OS account on xps-agent, **not** a mirror of desktop-agent's current real-home-directory setup. Desktop-agent's `nba-app` home contains default `/etc/skel` dotfiles (`.bashrc`, `.gtkrc-2.0`, etc.) — evidence it was created with a plain `useradd -m`, not evidence that an interactive shell is functionally required. Nothing in this deployment needs `nba-app` to log in: repo clones and `docker compose` invocations run as `sudo -u nba-app <single-command>` (proven non-interactive-safe by the fashion-monitor migration's identical pattern with `fashionmonitor`), and the containers themselves run under their own build images, not under `nba-app`'s shell. Membership in the `docker` group, not a login shell, is what makes those Docker invocations succeed against a root:docker-owned `docker.sock`. This matches the fleet's established service-account convention instead of silently copying an incidental, unhardened setup forward.

## Risk areas

1. **Volume name mismatch is the single highest-impact failure mode.** If `docker compose up -d` is ever run on xps-agent before the three named volumes are created and populated (or with `COMPOSE_PROJECT_NAME` unset or mismatched), Compose will create empty volumes and the migration will look successful (containers start, no errors) while silently running on no data — exactly the "synced to the host but not where the container reads from" gap the fashion-monitor migration hit. Mitigation: the plan orders volume restore strictly before first `up -d`, and Step 15's verification execs into each container to confirm expected files are present from inside it, not just on the host. That mitigation is only real, not illusory, if the check confirms non-empty / expected file presence — a check that only confirms an `ssh`+`ls` command exited 0 would pass even against an empty directory, silently validating the exact failure this risk describes (`steps.md` is being separately fixed to implement the check this way).
2. **Desktop-agent and xps-agent both live for up to 7 days.** AC14 requires desktop-agent to stay running (not just present) through the rollback window, so both instances will independently poll `balldontlie.io` with the same `BALLDONTLIE_API_KEY` during that window — roughly doubling call volume against that key. This is accepted as low risk (out of scope to rate-limit or rotate the key per the requirements) but worth knowing if `balldontlie.io` starts rate-limiting.
3. **`.env` transfer is operator-run, and its value-correctness is only hash-verified, not agent-inspected.** The direct SSH-to-SSH pipe (see Integration points) never displays the secret value, and the whole-file `sha256sum` comparison catches transcription corruption that the by-name `grep -c '^VAR='` check alone would miss — but the hash comparison only proves the two files are byte-identical, not that desktop-agent's original file held correct values in the first place. FR7 still forbids any agent tool call from touching the file's contents, so a pre-existing error in the source `.env` would carry through undetected by either check and would only surface as a failed or misbehaving container at verification time.
4. **A fresh `git clone` can silently pull code that doesn't match the migrated data.** `nba-analytics-hub`, `nba-data-service`, and `nba-predictor` are cloned fresh onto xps-agent, and a plain clone pulls the default branch's current tip — not necessarily the exact commit desktop-agent's checkouts are sitting at. Since `predictor-data-cache` and `predictor-artifacts` hold data generated by specific code, a version mismatch would let all three containers start cleanly with no errors while producing silently-wrong output — the same failure class as Risk area 1, but from a code/data mismatch instead of an empty volume. Mitigation: commit SHAs are captured from desktop-agent's checkouts and pinned via `git checkout <sha>` after cloning on xps-agent (see Integration points); a dirty desktop-agent checkout blocks the migration for human sign-off rather than being cloned around.
5. **The `[duration TBD]` in FR16/AC9 is resolved here to 10 minutes.** Reasoning: this migration's data is trivial (under 20KB total) and the compose file already carries `predictor`'s own working `command:` override (a persistent `uvicorn` process, despite `DEPLOYMENT.md`'s stale note that `Dockerfile.dev` "exits after setup" — that note predates the compose-level `command:` override and does not apply here), so a genuine crash-loop is unlikely; 10 minutes is long enough to observe several of Docker's own restart-backoff cycles if one is happening, short enough for an operator to babysit live during the migration session. No prior migration on this host pair had an equivalent timed-stability requirement to copy a number from, so this value is set fresh rather than reused.
