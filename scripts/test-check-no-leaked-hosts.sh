#!/usr/bin/env bash
# Regression test for scripts/check-no-leaked-hosts.sh.
#
# Proves the guard actually catches what it claims to catch: builds a
# disposable git repo with known-bad and known-good fixtures and asserts the
# guard exits non-zero on the bad fixture and zero on the clean one, for both
# the always-on RFC1918 check and the opt-in OPSEC_FORBIDDEN_LITERALS check.
#
# Usage: ./scripts/test-check-no-leaked-hosts.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$REPO_ROOT/scripts/check-no-leaked-hosts.sh"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

fail=0
pass_count=0

assert_exit() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" -eq "$expected" ]]; then
    echo "PASS: $desc"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $desc (expected exit $expected, got $actual)" >&2
    fail=1
  fi
}

new_fixture_repo() {
  local dir="$1"
  mkdir -p "$dir"
  (
    cd "$dir"
    git init -q
    git config user.email test@example.com
    git config user.name test
    mkdir -p scripts
    cp "$GUARD" "scripts/$(basename "$GUARD")"
    chmod +x "scripts/$(basename "$GUARD")"
  )
}

run_guard() {
  local dir="$1"
  shift
  ( cd "$dir" && env "$@" bash "scripts/$(basename "$GUARD")" )
}

# --- Case 1: clean tree, no env set -> guard must PASS -----------------------
CLEAN_REPO="$WORKDIR/clean"
new_fixture_repo "$CLEAN_REPO"
(
  cd "$CLEAN_REPO"
  echo "This doc mentions <vmhost> and <desktop-host> as placeholders only." >docs.md
  git add docs.md scripts
  git commit -q -m fixture
)
set +e
run_guard "$CLEAN_REPO"
rc=$?
set -e
assert_exit "clean tree with no real hosts/IPs passes" 0 "$rc"

# --- Case 2: RFC1918 literal present -> guard must FAIL (fail-to-pass) ------
BAD_IP_REPO="$WORKDIR/bad-ip"
new_fixture_repo "$BAD_IP_REPO"
(
  cd "$BAD_IP_REPO"
  echo "ssh agent@10.55.66.77" >notes.md
  git add notes.md scripts
  git commit -q -m fixture
)
set +e
run_guard "$BAD_IP_REPO"
rc=$?
set -e
assert_exit "a real RFC1918 address (10.55.66.77) is caught" 1 "$rc"

# 172.16-31.x.x and 192.168.x.x variants
for ip in "172.16.5.9" "172.31.0.1" "192.168.1.50"; do
  IP_REPO="$WORKDIR/bad-ip-$ip"
  new_fixture_repo "$IP_REPO"
  (
    cd "$IP_REPO"
    echo "host at $ip" >notes.md
    git add notes.md scripts
    git commit -q -m fixture
  )
  set +e
  run_guard "$IP_REPO"
  rc=$?
  set -e
  assert_exit "RFC1918 address $ip is caught" 1 "$rc"
done

# Public IPs must NOT trip the RFC1918 check.
PUBLIC_IP_REPO="$WORKDIR/public-ip"
new_fixture_repo "$PUBLIC_IP_REPO"
(
  cd "$PUBLIC_IP_REPO"
  echo "DNS: point an A record at 203.0.113.9" >notes.md
  git add notes.md scripts
  git commit -q -m fixture
)
set +e
run_guard "$PUBLIC_IP_REPO"
rc=$?
set -e
assert_exit "a public (non-RFC1918) IP does not trip the guard" 0 "$rc"

# --- Case 3: OPSEC_FORBIDDEN_LITERALS unset -> alias check skipped, stays green
ALIAS_REPO="$WORKDIR/alias-unset"
new_fixture_repo "$ALIAS_REPO"
(
  cd "$ALIAS_REPO"
  echo "ssh fake-lab-alias-for-test" >notes.md
  git add notes.md scripts
  git commit -q -m fixture
)
set +e
run_guard "$ALIAS_REPO"
rc=$?
set -e
assert_exit "host alias present but OPSEC_FORBIDDEN_LITERALS unset stays green" 0 "$rc"

# --- Case 4: OPSEC_FORBIDDEN_LITERALS set and literal present -> FAIL -------
set +e
run_guard "$ALIAS_REPO" OPSEC_FORBIDDEN_LITERALS="fake-lab-alias-for-test,some-other-host"
rc=$?
set -e
assert_exit "forbidden literal caught when OPSEC_FORBIDDEN_LITERALS is set" 1 "$rc"

# --- Case 5: OPSEC_FORBIDDEN_LITERALS set but literal absent -> PASS --------
set +e
run_guard "$CLEAN_REPO" OPSEC_FORBIDDEN_LITERALS="fake-lab-alias-for-test,some-other-host"
rc=$?
set -e
assert_exit "OPSEC_FORBIDDEN_LITERALS set but no match in clean tree passes" 0 "$rc"

echo
echo "$pass_count checks passed."
if [[ "$fail" -ne 0 ]]; then
  echo "test-check-no-leaked-hosts.sh: FAILURES ABOVE" >&2
  exit 1
fi
echo "test-check-no-leaked-hosts.sh: all checks passed."
