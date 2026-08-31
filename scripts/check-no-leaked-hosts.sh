#!/usr/bin/env bash
# Fails if a literal RFC1918 IPv4 address, or a real SSH host alias named via
# OPSEC_FORBIDDEN_LITERALS, appears in any tracked file in this repo.
#
# This script intentionally does NOT hardcode the host aliases it checks for --
# baking them in here would republish the exact strings this guard exists to
# keep out of a public repo. Instead:
#
#   OPSEC_FORBIDDEN_LITERALS  comma-separated list of literal strings to ban
#                             (e.g. real SSH config aliases for personal
#                             infra). Unset or empty -> that check is skipped,
#                             so a fork or a CI run without the list stays
#                             green. Set it as a repo/CI secret, not a file.
#
# The RFC1918 check always runs and needs no configuration: it bans any
# literal private-range IPv4 address (the three ranges reserved by RFC 1918)
# by pattern, matched generically so no real address needs to be written here.
#
# Usage: ./scripts/check-no-leaked-hosts.sh
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# Both this guard and its self-test (scripts/test-check-no-leaked-hosts.sh)
# necessarily contain pattern descriptions / synthetic example addresses to
# exercise the check -- exclude both from the scan they implement.
SELF_PATHS=(
  ":(exclude)scripts/$(basename "${BASH_SOURCE[0]}")"
  ":(exclude)scripts/test-check-no-leaked-hosts.sh"
)
fail=0

echo "== Checking tracked files for literal RFC1918 IPv4 addresses =="
# First octet 10 (/8); first octet 172 with second octet 16-31 (/12); or
# first two octets 192.168 (/16).
RFC1918_RE='(^|[^0-9.])(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3})([^0-9.]|$)'

if hits=$(git grep -InE "$RFC1918_RE" -- . "${SELF_PATHS[@]}" 2>/dev/null); then
  echo "$hits"
  echo "FAIL: literal RFC1918 address found in tracked files (see above)." >&2
  fail=1
else
  echo "OK: no RFC1918 literals found."
fi

if [[ -n "${OPSEC_FORBIDDEN_LITERALS:-}" ]]; then
  echo "== Checking tracked files for forbidden literals (OPSEC_FORBIDDEN_LITERALS) =="
  IFS=',' read -ra literals <<<"$OPSEC_FORBIDDEN_LITERALS"
  for raw in "${literals[@]}"; do
    # trim whitespace
    lit="${raw#"${raw%%[![:space:]]*}"}"
    lit="${lit%"${lit##*[![:space:]]}"}"
    [[ -z "$lit" ]] && continue
    if hits=$(git grep -InF -- "$lit" -- . "${SELF_PATHS[@]}" 2>/dev/null); then
      echo "$hits"
      echo "FAIL: a forbidden literal from OPSEC_FORBIDDEN_LITERALS was found in tracked files (see above; masked automatically in CI log output when set as a secret)." >&2
      fail=1
    fi
  done
  if [[ "$fail" -eq 0 ]]; then
    echo "OK: no forbidden literals found."
  fi
else
  echo "== OPSEC_FORBIDDEN_LITERALS not set; skipping host-alias literal check =="
fi

exit "$fail"
