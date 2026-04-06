#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/release-offline-project-bundle.sh <project-dir> [output-tar.gz]

Package a Rust project into a portable .tar.gz containing:

- the project source
- vendored Cargo dependencies
- a standalone Rust toolchain bundle
- bundle-local helper scripts and docs

Arguments:
  project-dir        Path to the Rust project to package
  output-tar.gz      Output artifact path
                     Default: <project-name>-offline-<target>.tar.gz

Environment:
  NATIVE_CC_ROOT         Existing musl C toolchain root to reuse
  RUST_TOOLCHAIN_DIR      Existing standalone toolchain dir to reuse
  RUST_TOOLCHAIN_VERSION  Toolchain version when building one (default: 1.94.1)
  RUST_TARGET             Rust target triple (default: x86_64-unknown-linux-musl)
  RUST_COMPONENTS         Optional Rust components for toolchain build
  BUNDLE_ROOT_NAME        Top-level directory name inside the tarball
  KEEP_WORKDIR            Keep temp directory after packaging when set to 1

Example:
  ./scripts/release-offline-project-bundle.sh /path/to/project
  ./scripts/release-offline-project-bundle.sh /path/to/project my-project-offline.tar.gz
EOF
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

abspath() {
  local path="$1"
  (cd "$path" && pwd -P)
}

build_musl_cc_root() {
  local out
  out="$(
    nix build --no-link --print-out-paths nixpkgs#pkgsCross.musl64.stdenv.cc \
      | awk '!/-man$/ { path = $0 } END { if (path != "") print path }'
  )"
  if [ -z "$out" ]; then
    echo "Failed to resolve musl C toolchain output from nixpkgs#pkgsCross.musl64.stdenv.cc" >&2
    exit 1
  fi
  printf '%s\n' "$out"
}

find_closure_tool() {
  local tool_name="$1"
  shift
  local store_path
  for store_path in "$@"; do
    if [ -x "$store_path/bin/$tool_name" ]; then
      printf '%s\n' "$store_path/bin/$tool_name"
      return 0
    fi
  done
  return 1
}

make_exec_wrapper() {
  local wrapper_path="$1"
  local target_path="$2"

  cat > "$wrapper_path" <<EOF
#!/bin/sh
exec "$target_path" "\$@"
EOF
  chmod +x "$wrapper_path"
}

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  usage
fi

need_cmd cargo
need_cmd tar
need_cmd mktemp
need_cmd nix
need_cmd nix-store
need_cmd sha256sum

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_DIR_INPUT="$1"
OUTPUT_TARBALL_INPUT="${2:-}"

if [ ! -d "$PROJECT_DIR_INPUT" ]; then
  echo "Project directory does not exist: $PROJECT_DIR_INPUT" >&2
  exit 1
fi

PROJECT_DIR="$(abspath "$PROJECT_DIR_INPUT")"
PROJECT_NAME="$(basename "$PROJECT_DIR")"
RUST_TOOLCHAIN_VERSION="${RUST_TOOLCHAIN_VERSION:-1.94.1}"
RUST_TARGET="${RUST_TARGET:-x86_64-unknown-linux-musl}"
RUST_TARGET_ENV="$(printf '%s' "$RUST_TARGET" | tr '[:lower:]-' '[:upper:]_')"
RUST_TARGET_CFG_ENV="$(printf '%s' "$RUST_TARGET" | tr '-' '_')"
CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/rust-musl-bundles"
TOOLCHAIN_DIR="${RUST_TOOLCHAIN_DIR:-$CACHE_ROOT/toolchain-${RUST_TOOLCHAIN_VERSION}-${RUST_TARGET}}"
NATIVE_CC_ROOT="${NATIVE_CC_ROOT:-}"
BUNDLE_ROOT_NAME="${BUNDLE_ROOT_NAME:-${PROJECT_NAME}-offline-${RUST_TARGET}}"
KEEP_WORKDIR="${KEEP_WORKDIR:-0}"

if [ -n "$OUTPUT_TARBALL_INPUT" ]; then
  case "$OUTPUT_TARBALL_INPUT" in
    /*) OUTPUT_TARBALL="$OUTPUT_TARBALL_INPUT" ;;
    *) OUTPUT_TARBALL="$PWD/$OUTPUT_TARBALL_INPUT" ;;
  esac
else
  OUTPUT_TARBALL="$PWD/${BUNDLE_ROOT_NAME}.tar.gz"
fi

WORKDIR="$(mktemp -d)"
BUNDLE_DIR="$WORKDIR/$BUNDLE_ROOT_NAME"
PROJECT_BUNDLE_DIR="$BUNDLE_DIR/project"
TOOLCHAIN_BUNDLE_DIR="$BUNDLE_DIR/rust-toolchain"
NATIVE_TOOLCHAIN_BUNDLE_DIR="$BUNDLE_DIR/native-toolchain"
NATIVE_TOOLCHAIN_STORE_DIR="$NATIVE_TOOLCHAIN_BUNDLE_DIR/nix/store"
CARGO_HOME_DIR="$BUNDLE_DIR/cargo-home"
VENDOR_CONFIG_FILE="$WORKDIR/cargo-vendor-config.toml"
README_FILE="$BUNDLE_DIR/README.md"
ACTIVATE_FILE="$BUNDLE_DIR/activate.sh"
BUILD_FILE="$BUNDLE_DIR/build-project.sh"
SHA256_FILE="${OUTPUT_TARBALL}.sha256"
METADATA_FILE="${OUTPUT_TARBALL}.metadata"

cleanup() {
  if [ "$KEEP_WORKDIR" = "1" ]; then
    echo "Kept temp directory: $WORKDIR"
  else
    chmod -R u+w "$WORKDIR" 2>/dev/null || true
    rm -rf "$WORKDIR" || true
  fi
}
trap cleanup EXIT

echo "Preparing project bundle from $PROJECT_DIR ..."
mkdir -p "$PROJECT_BUNDLE_DIR"
tar \
  -C "$PROJECT_DIR" \
  --exclude=.git \
  --exclude=.direnv \
  --exclude=target \
  -cf - . | tar -C "$PROJECT_BUNDLE_DIR" -xf -

echo "Vendoring Cargo dependencies ..."
(
  cd "$PROJECT_BUNDLE_DIR"
  cargo vendor --locked --versioned-dirs vendor > "$VENDOR_CONFIG_FILE"
)

mkdir -p "$CARGO_HOME_DIR"
sed -E 's#^directory = .*$#directory = "project/vendor"#' "$VENDOR_CONFIG_FILE" > "$CARGO_HOME_DIR/config.toml"

if [ ! -d "$TOOLCHAIN_DIR" ]; then
  echo "Building standalone Rust toolchain ..."
  mkdir -p "$(dirname "$TOOLCHAIN_DIR")"
  "$SCRIPT_DIR/build-standalone-toolchain-dir.sh" "$TOOLCHAIN_DIR" "$RUST_TOOLCHAIN_VERSION" "$RUST_TARGET"
else
  echo "Reusing standalone Rust toolchain: $TOOLCHAIN_DIR"
fi

cp -a "$TOOLCHAIN_DIR" "$TOOLCHAIN_BUNDLE_DIR"

if [ -z "$NATIVE_CC_ROOT" ]; then
  echo "Building musl C toolchain ..."
  NATIVE_CC_ROOT="$(build_musl_cc_root)"
else
  echo "Reusing musl C toolchain: $NATIVE_CC_ROOT"
fi

mapfile -t NATIVE_CLOSURE_PATHS < <(nix-store -qR "$NATIVE_CC_ROOT" | sort -u)
NATIVE_TOOL_SEARCH_PATHS=("$NATIVE_CC_ROOT" "${NATIVE_CLOSURE_PATHS[@]}")
NATIVE_CC_PATH="$(find_closure_tool "${RUST_TARGET}-gcc" "${NATIVE_TOOL_SEARCH_PATHS[@]}" || true)"
NATIVE_CXX_PATH="$(find_closure_tool "${RUST_TARGET}-g++" "${NATIVE_TOOL_SEARCH_PATHS[@]}" || true)"
NATIVE_AR_PATH="$(find_closure_tool "${RUST_TARGET}-ar" "${NATIVE_TOOL_SEARCH_PATHS[@]}" || true)"
NATIVE_RANLIB_PATH="$(find_closure_tool "${RUST_TARGET}-ranlib" "${NATIVE_TOOL_SEARCH_PATHS[@]}" || true)"

if [ -z "$NATIVE_CC_PATH" ] || [ -z "$NATIVE_CXX_PATH" ] || [ -z "$NATIVE_AR_PATH" ] || [ -z "$NATIVE_RANLIB_PATH" ]; then
  echo "Failed to locate full musl native toolchain in closure rooted at: $NATIVE_CC_ROOT" >&2
  exit 1
fi

mkdir -p "$NATIVE_TOOLCHAIN_BUNDLE_DIR/bin" "$NATIVE_TOOLCHAIN_STORE_DIR"
for store_path in "${NATIVE_CLOSURE_PATHS[@]}"; do
  cp -a "$store_path" "$NATIVE_TOOLCHAIN_STORE_DIR/"
done
chmod -R u+w "$NATIVE_TOOLCHAIN_BUNDLE_DIR" 2>/dev/null || true

make_exec_wrapper "$NATIVE_TOOLCHAIN_BUNDLE_DIR/bin/cc" "$NATIVE_CC_PATH"
make_exec_wrapper "$NATIVE_TOOLCHAIN_BUNDLE_DIR/bin/gcc" "$NATIVE_CC_PATH"
make_exec_wrapper "$NATIVE_TOOLCHAIN_BUNDLE_DIR/bin/${RUST_TARGET}-gcc" "$NATIVE_CC_PATH"
make_exec_wrapper "$NATIVE_TOOLCHAIN_BUNDLE_DIR/bin/c++" "$NATIVE_CXX_PATH"
make_exec_wrapper "$NATIVE_TOOLCHAIN_BUNDLE_DIR/bin/g++" "$NATIVE_CXX_PATH"
make_exec_wrapper "$NATIVE_TOOLCHAIN_BUNDLE_DIR/bin/${RUST_TARGET}-g++" "$NATIVE_CXX_PATH"
make_exec_wrapper "$NATIVE_TOOLCHAIN_BUNDLE_DIR/bin/ar" "$NATIVE_AR_PATH"
make_exec_wrapper "$NATIVE_TOOLCHAIN_BUNDLE_DIR/bin/${RUST_TARGET}-ar" "$NATIVE_AR_PATH"
make_exec_wrapper "$NATIVE_TOOLCHAIN_BUNDLE_DIR/bin/ranlib" "$NATIVE_RANLIB_PATH"
make_exec_wrapper "$NATIVE_TOOLCHAIN_BUNDLE_DIR/bin/${RUST_TARGET}-ranlib" "$NATIVE_RANLIB_PATH"

cat > "$ACTIVATE_FILE" <<EOF
if ! (return 0 2>/dev/null); then
  echo "Source this file from the bundle root:" >&2
  echo "  . ./activate.sh" >&2
  exit 1
fi

_bundle_dir="\$(pwd -P)"
if [ ! -f "\$_bundle_dir/rust-toolchain/activate.sh" ] || [ ! -d "\$_bundle_dir/project" ]; then
  echo "Run this from the extracted bundle root before sourcing activate.sh." >&2
  return 1
fi

_native_store="\$_bundle_dir/native-toolchain/nix/store"
if [ -d "\$_native_store" ] && [ ! -e /nix/store ]; then
  mkdir -p /nix 2>/dev/null || true
  ln -sfn "\$_native_store" /nix/store 2>/dev/null || true
fi
if [ -d "\$_native_store" ] && [ ! -e /nix/store ]; then
  echo "Native toolchain setup failed. If your project needs C/linker tools, run as root or create:" >&2
  echo "  /nix/store -> \$_native_store" >&2
  return 1
fi

. "\$_bundle_dir/rust-toolchain/activate.sh"
export PATH="\$_bundle_dir/native-toolchain/bin:\$PATH"
export CARGO_HOME="\$_bundle_dir/cargo-home"
export CARGO_NET_OFFLINE=true
export CC=cc
export CXX=c++
export AR=ar
export RANLIB=ranlib
export CC_${RUST_TARGET_CFG_ENV}=cc
export CXX_${RUST_TARGET_CFG_ENV}=c++
export AR_${RUST_TARGET_CFG_ENV}=ar
export CARGO_TARGET_${RUST_TARGET_ENV}_LINKER=cc

unset _native_store
unset _bundle_dir
EOF

cat > "$BUILD_FILE" <<EOF
#!/bin/sh
set -eu

bundle_dir=\$(CDPATH= cd -- "\$(dirname -- "\$0")" && pwd -P)
native_store="\$bundle_dir/native-toolchain/nix/store"

if [ -d "\$native_store" ] && [ ! -e /nix/store ]; then
  mkdir -p /nix 2>/dev/null || true
  ln -sfn "\$native_store" /nix/store 2>/dev/null || true
fi
if [ -d "\$native_store" ] && [ ! -e /nix/store ]; then
  echo "Native toolchain setup failed. Create /nix/store -> \$native_store or run as root." >&2
  exit 1
fi

export PATH="\$bundle_dir/native-toolchain/bin:\$bundle_dir/rust-toolchain/bin:\$PATH"
export LD_LIBRARY_PATH="\$bundle_dir/rust-toolchain/lib:\$bundle_dir/rust-toolchain/toolchain/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
export CARGO_HOME="\$bundle_dir/cargo-home"
export CARGO_NET_OFFLINE=true
export CC=cc
export CXX=c++
export AR=ar
export RANLIB=ranlib
export CC_${RUST_TARGET_CFG_ENV}=cc
export CXX_${RUST_TARGET_CFG_ENV}=c++
export AR_${RUST_TARGET_CFG_ENV}=ar
export CARGO_TARGET_${RUST_TARGET_ENV}_LINKER=cc

cd "\$bundle_dir/project"
exec cargo build --frozen --offline --target ${RUST_TARGET} "\$@"
EOF
chmod +x "$BUILD_FILE"

cat > "$README_FILE" <<'EOF'
# Offline Rust project bundle

This bundle contains:

- \`project/\`: your Rust project source
- \`project/vendor/\`: vendored Cargo dependencies
- \`cargo-home/config.toml\`: bundle-local Cargo source replacement
- \`rust-toolchain/\`: standalone Rust toolchain bundle
- \`native-toolchain/\`: bundled musl C/linker toolchain
- \`activate.sh\`: sourceable environment setup
- \`build-project.sh\`: one-shot offline build helper

## Quick start

Unpack the tarball, enter the bundle root, then either:

```bash
./build-project.sh --release
```

or:

```bash
. ./activate.sh
cd project
cargo build --frozen --offline --target ${RUST_TARGET}
```

## Notes

- Source \`activate.sh\`; do not execute it directly.
- \`activate.sh\` must be sourced from the extracted bundle root.
- The toolchain defaults to the \`${RUST_TARGET}\` target.
- The bundle is Nix-free once produced.
- The native musl toolchain is shipped under \`native-toolchain/nix/store\`.
- If \`/nix/store\` does not exist, \`activate.sh\` and \`build-project.sh\` try to create a symlink to the bundled store. That requires permission to write \`/nix\`.

## Limitation

Vendored Cargo dependencies and the bundled musl \`cc\` toolchain solve Rust
crate resolution and basic native linking, but they do not bundle arbitrary
system libraries. Projects that need tools such as \`pkg-config\` or external
libraries such as OpenSSL may still require extra host setup.
EOF

sed -i "s#\${RUST_TARGET}#${RUST_TARGET}#g" "$README_FILE"

mkdir -p "$(dirname "$OUTPUT_TARBALL")"
echo "Creating release artifact: $OUTPUT_TARBALL"
tar -C "$WORKDIR" -czf "$OUTPUT_TARBALL" "$BUNDLE_ROOT_NAME"
sha256sum "$OUTPUT_TARBALL" > "$SHA256_FILE"

cat > "$METADATA_FILE" <<EOF
artifact=$(basename "$OUTPUT_TARBALL")
project_name=$PROJECT_NAME
rust_toolchain_version=$RUST_TOOLCHAIN_VERSION
rust_target=$RUST_TARGET
bundle_root_name=$BUNDLE_ROOT_NAME
sha256=$(awk '{print $1}' "$SHA256_FILE")
EOF

echo "Created offline project bundle:"
echo "  $OUTPUT_TARBALL"
echo "  $SHA256_FILE"
echo "  $METADATA_FILE"
