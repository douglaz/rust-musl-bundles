#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/release-standalone-toolchain-tarball.sh <output-tarball> [version] [target]

Build the Nix-free toolchain bundle and package it as a .tar.gz release artifact.

Arguments:
  output-tarball  Path for the output .tar.gz file (required)
  version         Rust stable version, e.g. 1.94.1
  target          Rust target triple (default: x86_64-unknown-linux-musl)

Example:
  ./scripts/release-standalone-toolchain-tarball.sh rust-toolchain-1.94.1-x86_64-unknown-linux-musl.tar.gz 1.94.1
EOF
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

need_cmd tar
need_cmd sha256sum
need_cmd mktemp
need_cmd printf

if [ "${1-}" = "" ]; then
  usage
fi

OUT_TARBALL="${1}"
VERSION="${2-}"
TARGET="${3:-x86_64-unknown-linux-musl}"
if [[ "$OUT_TARBALL" != *.tar.gz ]]; then
  OUT_TARBALL="${OUT_TARBALL}.tar.gz"
fi

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
WORKDIR="$(mktemp -d)"
TMP_ROOT="$(mktemp -d)"
TMP_STAMP_FILE="$TMP_ROOT/release.info"
TMP_TAR="$WORKDIR/rust-toolchain.tar"
trap 'rm -rf "$WORKDIR" "$TMP_ROOT"' EXIT

VERSION_LABEL="${VERSION:-latest}"
ARCHIVE_NAME="rust-toolchain-${VERSION_LABEL}-${TARGET}"
STAGE_DIR="$WORKDIR/$ARCHIVE_NAME"
mkdir -p "$(dirname -- "$OUT_TARBALL")"

if [ -n "$VERSION" ]; then
  "$SCRIPT_DIR/build-standalone-toolchain-dir.sh" "$STAGE_DIR" "$VERSION" "$TARGET"
else
  "$SCRIPT_DIR/build-standalone-toolchain-dir.sh" "$STAGE_DIR" "" "$TARGET"
fi

tar -cf "$TMP_TAR" -C "$WORKDIR" "$ARCHIVE_NAME"

SHA256SUM_FILE="${OUT_TARBALL}.sha256"

printf '%s\n' "$VERSION_LABEL" > "$TMP_STAMP_FILE"
printf '%s\n' "$TARGET" >> "$TMP_STAMP_FILE"
tar -rf "$TMP_TAR" -C "$TMP_ROOT" release.info
gzip -9 -c "$TMP_TAR" > "$OUT_TARBALL"
sha256sum "$OUT_TARBALL" > "$SHA256SUM_FILE"

cat > "${OUT_TARBALL}.metadata" <<EOF
artifact=$OUT_TARBALL
version=$VERSION_LABEL
target=$TARGET
sha256=$(awk '{print $1}' "$SHA256SUM_FILE")
EOF

echo "Created release artifact:"
echo "  $OUT_TARBALL"
echo "  $SHA256SUM_FILE"
echo "  ${OUT_TARBALL}.metadata"
