#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/rust-musl-bundles"

echo "Removing repo-local generated artifacts ..."
rm -rf \
  "$REPO_ROOT/result" \
  "$REPO_ROOT/dist" \
  "$REPO_ROOT/rust-toolchain"

find "$REPO_ROOT" -maxdepth 1 \
  \( -name '*.tar.gz' -o -name '*.tar.gz.sha256' -o -name '*.tar.gz.metadata' \) \
  -delete

echo "Removing helper cache ..."
rm -rf "$CACHE_ROOT"

echo "Cleaned:"
echo "  $REPO_ROOT/result"
echo "  $REPO_ROOT/dist"
echo "  $REPO_ROOT/rust-toolchain"
echo "  $REPO_ROOT/*.tar.gz*"
echo "  $CACHE_ROOT"
