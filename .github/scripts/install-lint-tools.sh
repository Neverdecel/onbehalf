#!/usr/bin/env bash
# Install the lint tools CI needs, pinned by version and sha256.
# Bump a tool: change its version and checksum together (Dependabot cannot).
set -euo pipefail

BIN=${1:-$HOME/.local/bin}
mkdir -p "$BIN"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fetch() { # fetch <url> <sha256> <file>
  curl -fsSL --retry 3 "$1" -o "$tmp/$3"
  echo "$2  $tmp/$3" | sha256sum -c --quiet -
}

SHFMT=v3.14.1
fetch "https://github.com/mvdan/sh/releases/download/$SHFMT/shfmt_${SHFMT}_linux_amd64" \
  76e77641faa025814b77f153b29796b8e6fa2fca03e0c76a691608b86c7ea7bf shfmt
install -m 0755 "$tmp/shfmt" "$BIN/shfmt"

ACTIONLINT=1.7.12
fetch "https://github.com/rhysd/actionlint/releases/download/v$ACTIONLINT/actionlint_${ACTIONLINT}_linux_amd64.tar.gz" \
  8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8 actionlint.tgz
tar -xzf "$tmp/actionlint.tgz" -C "$BIN" actionlint

HADOLINT=v2.15.1
fetch "https://github.com/hadolint/hadolint/releases/download/$HADOLINT/hadolint-linux-x86_64" \
  c7187db94eeeeca956519a6af171adc31453941a1e777961f6e680f697c8c507 hadolint
install -m 0755 "$tmp/hadolint" "$BIN/hadolint"
