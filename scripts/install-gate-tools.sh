#!/usr/bin/env bash
# Install the pinned tools the gates need on a Linux x86_64 runner. Used by CI and by developers.
#   install-gate-tools.sh [BIN_DIR]     (default: $HOME/.local/bin; put it on PATH)
# Every download is checked against a SHA-256 below. Python tools come from a hash-locked file and
# jscpd from package-lock.json, so a moved tag or a hijacked package fails the install.
# The Trivy, Vale and actionlint hashes come from each project's published checksum file. The
# ShellCheck, shfmt, hadolint and bats hashes were computed from the release asset when pinned,
# because those releases publish no checksum file.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${1:-$HOME/.local/bin}"

SHELLCHECK_VERSION=0.11.0
SHFMT_VERSION=3.14.1
HADOLINT_VERSION=2.15.1
TRIVY_VERSION=0.76.2
VALE_VERSION=3.27.0
ACTIONLINT_VERSION=1.7.7
BATS_VERSION=1.13.0

SHELLCHECK_SHA=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
SHFMT_SHA=76e77641faa025814b77f153b29796b8e6fa2fca03e0c76a691608b86c7ea7bf
HADOLINT_SHA=c7187db94eeeeca956519a6af171adc31453941a1e777961f6e680f697c8c507
TRIVY_SHA=bc0fc726e017b8927a62b2d3531d7a84ee01769daf5c99ed866dced54089fdbf
VALE_SHA=c80d62f6bce87b81843ac5b512a26e63213927b957adba0a64fc594570da2000
ACTIONLINT_SHA=023070a287cd8cccd71515fedc843f1985bf96c436b7effaecce67290e7e0757
BATS_SHA=a85e12b8828271a152b338ca8109aa23493b57950987c8e6dff97ba492772ff3

log() { echo "install-gate-tools: $*" >&2; }
die() {
  log "$*"
  exit "${2:-1}"
}
need() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1" 127; }

# fetch URL SHA256 FILE: download to FILE, then fail unless the hash matches.
fetch() {
  local url="$1" sha="$2" file="$3" actual
  curl --fail --silent --show-error --location --output "$file" "$url"
  actual="$(sha256sum "$file" | cut -d' ' -f1)"
  [ "$actual" = "$sha" ] || die "checksum mismatch for $url (got $actual)"
}

install_archive_tool() {
  local name="$1" url="$2" sha="$3" member="$4" archive
  archive="$WORK/$name.archive"
  fetch "$url" "$sha" "$archive"
  mkdir -p "$WORK/$name"
  tar -xf "$archive" -C "$WORK/$name"
  install -m 0755 "$WORK/$name/$member" "$BIN/$name"
}

install_binary_tool() {
  local name="$1" url="$2" sha="$3"
  fetch "$url" "$sha" "$WORK/$name"
  install -m 0755 "$WORK/$name" "$BIN/$name"
}

install_python_tools() {
  python3 -m venv "$BIN/../gate-venv"
  "$BIN/../gate-venv/bin/pip" install --quiet --require-hashes -r "$ROOT/gate-tools/requirements.txt"
  ln -sf "$BIN/../gate-venv/bin/lizard" "$BIN/lizard"
  ln -sf "$BIN/../gate-venv/bin/zizmor" "$BIN/zizmor"
}

install_jscpd() {
  (cd "$ROOT/gate-tools" && npm ci --ignore-scripts --silent)
  ln -sf "$ROOT/gate-tools/node_modules/.bin/jscpd" "$BIN/jscpd"
}

install_bats() {
  local dir="$WORK/bats-src"
  fetch "https://github.com/bats-core/bats-core/archive/refs/tags/v$BATS_VERSION.tar.gz" "$BATS_SHA" "$WORK/bats.tar.gz"
  mkdir -p "$dir"
  tar -xzf "$WORK/bats.tar.gz" -C "$dir" --strip-components=1
  "$dir/install.sh" "$BIN/.." >/dev/null
}

main() {
  need curl
  need tar
  need python3
  need npm
  mkdir -p "$BIN"
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT

  local gh=https://github.com
  install_archive_tool shellcheck "$gh/koalaman/shellcheck/releases/download/v$SHELLCHECK_VERSION/shellcheck-v$SHELLCHECK_VERSION.linux.x86_64.tar.xz" "$SHELLCHECK_SHA" "shellcheck-v$SHELLCHECK_VERSION/shellcheck"
  install_binary_tool shfmt "$gh/mvdan/sh/releases/download/v$SHFMT_VERSION/shfmt_v${SHFMT_VERSION}_linux_amd64" "$SHFMT_SHA"
  install_binary_tool hadolint "$gh/hadolint/hadolint/releases/download/v$HADOLINT_VERSION/hadolint-linux-x86_64" "$HADOLINT_SHA"
  install_archive_tool trivy "$gh/aquasecurity/trivy/releases/download/v$TRIVY_VERSION/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz" "$TRIVY_SHA" trivy
  install_archive_tool vale "$gh/vale-cli/vale/releases/download/v$VALE_VERSION/vale_${VALE_VERSION}_Linux_64-bit.tar.gz" "$VALE_SHA" vale
  install_archive_tool actionlint "$gh/rhysd/actionlint/releases/download/v$ACTIONLINT_VERSION/actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz" "$ACTIONLINT_SHA" actionlint
  install_bats
  install_python_tools
  install_jscpd
  log "installed into $BIN"
}

main "$@"
