#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/build-standalone-toolchain-dir.sh <output-dir> [version] [target]

Build a self-contained Rust toolchain directory for machines without Nix.

Arguments:
  output-dir  Destination directory (required)
  version     Rust stable version, e.g. 1.94.1
  target      Rust target triple (default: x86_64-unknown-linux-musl)

Example:
  RUST_CHANNEL_MANIFEST=https://static.rust-lang.org/dist/channel-rust-stable.toml \\
    scripts/build-standalone-toolchain-dir.sh ./rust-toolchain 1.94.1 x86_64-unknown-linux-musl

Environment:
  RUST_COMPONENTS  Comma-separated Rust dist components to install.
                   Default: cargo,rustc,rust-std-<target>
EOF
  exit 1
}

if [ "${1-}" = "" ]; then
  usage
fi

OUTDIR="${1}"
VERSION="${2-}"
TARGET="${3:-x86_64-unknown-linux-musl}"
MANIFEST_URL="${RUST_CHANNEL_MANIFEST:-https://static.rust-lang.org/dist/channel-rust-stable.toml}"
DEFAULT_COMPONENTS="cargo,rustc,rust-std-${TARGET}"
COMPONENTS="${RUST_COMPONENTS:-$DEFAULT_COMPONENTS}"
TARGET_ENV_SUFFIX="$(printf '%s' "$TARGET" | tr '-' '_')"
TARGET_CC_VAR="CC_${TARGET_ENV_SUFFIX}"
TARGET_LINKER_VAR="CARGO_TARGET_$(printf '%s' "$TARGET" | tr '[:lower:]-' '[:upper:]_')_LINKER"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

need_cmd curl
need_cmd tar
need_cmd readelf
need_cmd awk
need_cmd sed
need_cmd file

fetch_version() {
  local manifest="$1"
  awk '
    /^\[pkg\.rust\]/ { in_pkg=1; next }
    in_pkg && /^version[[:space:]]*=/ {
      split($0,a,"=");
      gsub(/["[:space:]]/, "", a[2]);
      print a[2];
      exit
    }
    in_pkg && /^\[/ { exit }
  ' "$manifest"
}

if [ -z "$VERSION" ]; then
  tmp_manifest="$(mktemp)"
  curl -fsSL "$MANIFEST_URL" -o "$tmp_manifest"
  VERSION="$(fetch_version "$tmp_manifest")"
  if [ -z "$VERSION" ]; then
    echo "Failed to parse version from manifest: $MANIFEST_URL" >&2
    exit 1
  fi
fi

ARCHIVE="rust-${VERSION}-${TARGET}"
URL="https://static.rust-lang.org/dist/${ARCHIVE}.tar.xz"
tmpdir="$(mktemp -d)"
tmp_manifest="${tmp_manifest:-}"
trap 'rm -rf "$tmpdir"; rm -f "$tmp_manifest"' EXIT

echo "Downloading $URL ..."
curl -fsSL "$URL" -o "$tmpdir/${ARCHIVE}.tar.xz"
mkdir -p "$tmpdir/extract"
tar -xJf "$tmpdir/${ARCHIVE}.tar.xz" -C "$tmpdir/extract"

SRC_DIR="$tmpdir/extract/$ARCHIVE"
if [ ! -d "$SRC_DIR" ]; then
  echo "Unexpected archive layout. Expected $ARCHIVE directory." >&2
  exit 1
fi

rm -rf "$OUTDIR"
mkdir -p "$OUTDIR/bin" "$OUTDIR/lib" "$OUTDIR/toolchain"

echo "Preparing toolchain in $OUTDIR ..."
"$SRC_DIR/install.sh" \
  --prefix="$OUTDIR/toolchain" \
  --disable-ldconfig \
  --components="$COMPONENTS"

if [ ! -d "$OUTDIR/toolchain/bin" ]; then
  echo "Toolchain install failed: missing $OUTDIR/toolchain/bin" >&2
  exit 1
fi

declare -A COPIED_LIBS

copy_lib() {
  local libfile="$1"
  local dst_name="${2:-$(basename "$libfile")}"
  [ -n "$libfile" ] || return 0
  [ -e "$libfile" ] || return 0
  local dst="$OUTDIR/lib/$dst_name"
  if [ -z "${COPIED_LIBS[$dst_name]+x}" ]; then
    cp -Lf "$libfile" "$dst"
    COPIED_LIBS["$dst_name"]=1
  fi
}

check_dir_for_lib() {
  local dir="$1"
  local name="$2"
  [ -n "$dir" ] || return 1
  [ -e "$dir/$name" ] || return 1
  if ! file -LbL "$dir/$name" | grep -q "ELF"; then
    return 1
  fi
  echo "$dir/$name"
  return 0
}

query_compiler_for_lib() {
  local compiler="$1"
  local name="$2"
  local hit
  [ -n "$compiler" ] || return 1
  command -v "$compiler" >/dev/null 2>&1 || return 1
  hit="$("$compiler" -print-file-name="$name" 2>/dev/null || true)"
  [ -n "$hit" ] || return 1
  [ "$hit" != "$name" ] || return 1
  [ -e "$hit" ] || return 1
  if ! file -LbL "$hit" | grep -q "ELF"; then
    return 1
  fi
  echo "$hit"
  return 0
}

query_compiler_search_dirs() {
  local compiler="$1"
  local name="$2"
  local dirs
  local dir
  local old_ifs

  [ -n "$compiler" ] || return 1
  command -v "$compiler" >/dev/null 2>&1 || return 1

  dirs="$("$compiler" -print-search-dirs 2>/dev/null | awk -F'libraries: ' '/^libraries: / { print $2; exit }')"
  [ -n "$dirs" ] || return 1
  dirs="${dirs#=}"

  old_ifs="$IFS"
  IFS=':'
  for dir in $dirs; do
    check_dir_for_lib "$dir" "$name" && {
      IFS="$old_ifs"
      return 0
    }
  done
  IFS="$old_ifs"

  return 1
}

locate_lib() {
  local name="$1"
  local hit
  local flags
  local token
  local expect_path=""
  local target_compiler="${!TARGET_CC_VAR-}"
  local target_linker="${!TARGET_LINKER_VAR-}"

  query_compiler_for_lib "$target_compiler" "$name" && return 0
  query_compiler_for_lib "$target_linker" "$name" && return 0
  query_compiler_search_dirs "$target_compiler" "$name" && return 0
  query_compiler_search_dirs "$target_linker" "$name" && return 0

  for pattern in \
    "/nix/store/"*"-${TARGET}-"*"/${TARGET}/lib/${name}" \
    "/nix/store/"*"-${TARGET}-"*"/lib/${name}" \
    "/nix/store/"*"-${TARGET}-"*"/lib64/${name}"; do
    if [ -e "$pattern" ] && file -LbL "$pattern" | grep -q "ELF"; then
      echo "$pattern"
      return 0
    fi
  done

  for p in \
    "/lib" \
    "/lib64" \
    "/usr/lib" \
    "/usr/lib64" \
    "/usr/lib/x86_64-linux-gnu" \
    "/lib/x86_64-linux-musl" \
    "/lib/x86_64-linux-gnu" \
    "/usr/local/lib"; do
    check_dir_for_lib "$p" "$name" && return 0
  done

  for path_list in "${LD_LIBRARY_PATH-}" "${LIBRARY_PATH-}"; do
    old_ifs="$IFS"
    IFS=':'
    for p in $path_list; do
      check_dir_for_lib "$p" "$name" && {
        IFS="$old_ifs"
        return 0
      }
    done
    IFS="$old_ifs"
  done

  for flags in "${NIX_LDFLAGS-}" "${NIX_LDFLAGS_BEFORE-}" "${NIX_CFLAGS_LINK-}" "${LDFLAGS-}"; do
    expect_path=""
    for token in $flags; do
      if [ -n "$expect_path" ]; then
        check_dir_for_lib "$token" "$name" && return 0
        expect_path=""
        continue
      fi

      case "$token" in
        -L|-rpath|-Wl,-rpath)
          expect_path=1
          ;;
        -L*)
          check_dir_for_lib "${token#-L}" "$name" && return 0
          ;;
        -rpath=*)
          check_dir_for_lib "${token#-rpath=}" "$name" && return 0
          ;;
        -Wl,-rpath,*)
          check_dir_for_lib "${token#-Wl,-rpath,}" "$name" && return 0
          ;;
        -Wl,-rpath=*)
          check_dir_for_lib "${token#-Wl,-rpath=}" "$name" && return 0
          ;;
      esac
    done
  done

  if command -v cc >/dev/null 2>&1; then
    hit="$(cc -print-file-name="$name" 2>/dev/null || true)"
    if [ -n "$hit" ] && [ "$hit" != "$name" ] && [ -e "$hit" ]; then
      echo "$hit"
      return 0
    fi
  fi

  if command -v ldconfig >/dev/null 2>&1; then
    hit="$(ldconfig -p 2>/dev/null | awk -v name="$name" '$1 == name {print $NF; exit}')"
    if [ -n "$hit" ]; then
      echo "$hit"
      return 0
    fi
  fi

  for pattern in \
    "/nix/store/"*/lib/"$name" \
    "/nix/store/"*/lib64/"$name"; do
    if [ -e "$pattern" ]; then
      echo "$pattern"
      return 0
    fi
  done

  return 1
}

collect_elf_deps() {
  local f="$1"
  readelf -d "$f" 2>/dev/null | awk -F'[\\[\\]]' '/NEEDED/{print $2}'
}

collect_interpreter() {
  local f="$1"
  readelf -l "$f" 2>/dev/null | awk -F'[][]' '/Requesting program interpreter:/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}'
}

LOADER=""

while IFS= read -r -d '' bin; do
  [ -f "$bin" ] || continue
  if file "$bin" | grep -q "ELF"; then
    for dep in $(collect_elf_deps "$bin"); do
      [ "$dep" = "linux-vdso.so.1" ] && continue
      if ! [ -f "$OUTDIR/toolchain/lib/$dep" ] && ! [ -f "$OUTDIR/lib/$dep" ]; then
        if path="$(locate_lib "$dep")"; then
          copy_lib "$path" "$dep"
        else
          echo "warning: missing system library '$dep' for $(basename "$bin")" >&2
        fi
      fi
    done
  fi
  interp="$(collect_interpreter "$bin" || true)"
  if [ -n "$interp" ] && [ "$LOADER" = "" ]; then
    LOADER="$(basename "$interp")"
  fi
done < <(find "$OUTDIR/toolchain/bin" -maxdepth 1 -type f -print0)

if [ -n "$LOADER" ]; then
  if ! [ -e "$OUTDIR/lib/$LOADER" ]; then
    interp_path="$(collect_interpreter "$OUTDIR/toolchain/bin/rustc" || true)"
    if [ -z "$interp_path" ]; then
      for candidate in "$OUTDIR/toolchain/bin/cargo" "$OUTDIR/toolchain/bin/rustc"; do
        if [ -f "$candidate" ] && file "$candidate" | grep -q "ELF"; then
          interp_path="$(collect_interpreter "$candidate" || true)"
          [ -n "$interp_path" ] && break
        fi
      done
    fi
    if [ -n "${interp_path-}" ] && [ -e "$interp_path" ]; then
      copy_lib "$interp_path" "$LOADER"
    elif path="$(locate_lib "$LOADER")"; then
      copy_lib "$path" "$LOADER"
    elif [[ "$LOADER" == ld-musl-* ]] && path="$(locate_lib "libc.so")"; then
      copy_lib "$path" "$LOADER"
    else
      echo "Missing loader '$LOADER' for bundled toolchain" >&2
      exit 1
    fi
    chmod 755 "$OUTDIR/lib/$LOADER"
  fi
fi

for src in "$OUTDIR/toolchain/bin/"*; do
  [ -f "$src" ] || continue
  name="$(basename "$src")"
  wrapper="$OUTDIR/bin/$name"

  if file "$src" | grep -q "ASCII text"; then
    cp -f "$src" "$wrapper"
    chmod +x "$wrapper"
    continue
  fi

  cat > "$wrapper" <<EOF
#!/bin/sh
set -eu

ROOT_DIR="\$(CDPATH= cd -- "\$(dirname -- "\$0")/.." && pwd)"
TOOLCHAIN="\$ROOT_DIR/toolchain"
RUNTIME_LIB_DIR="\$ROOT_DIR/lib"
TOOLCHAIN_LIB_DIR="\$TOOLCHAIN/lib"

if [ -n "\${LD_LIBRARY_PATH:-}" ]; then
  export LD_LIBRARY_PATH="\$RUNTIME_LIB_DIR:\$TOOLCHAIN_LIB_DIR:\$LD_LIBRARY_PATH"
else
  export LD_LIBRARY_PATH="\$RUNTIME_LIB_DIR:\$TOOLCHAIN_LIB_DIR"
fi

if [ -n "\$ROOT_DIR" ] && [ -x "\$RUNTIME_LIB_DIR/$LOADER" ]; then
  exec "\$RUNTIME_LIB_DIR/$LOADER" "\$TOOLCHAIN/bin/$name" "\$@"
fi

exec "\$TOOLCHAIN/bin/$name" "\$@"
EOF
  chmod +x "$wrapper"
done

cat > "$OUTDIR/activate.sh" <<'EOF'
#!/bin/sh
if [ -n "${BASH_SOURCE:-}" ]; then
  ACTIVATE_SOURCE="${BASH_SOURCE[0]}"
else
  ACTIVATE_SOURCE="$0"
fi
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$ACTIVATE_SOURCE")" && pwd)"
unset ACTIVATE_SOURCE
export PATH="$SCRIPT_DIR/bin:$PATH"
export LD_LIBRARY_PATH="$SCRIPT_DIR/lib:$SCRIPT_DIR/toolchain/lib:${LD_LIBRARY_PATH:-}"
EOF
chmod +x "$OUTDIR/activate.sh"

cat > "$OUTDIR/README.md" <<EOF
# Portable Rust Toolchain

This directory contains a self-contained Rust toolchain bundle prepared for:

- version: \`${VERSION}\`
- target: \`${TARGET}\`

## Quick Start

From this directory, source the activation script:

\`\`\`bash
. ./activate.sh
\`\`\`

Do not run \`./activate.sh\` directly. It must be sourced so it can update your
current shell's \`PATH\` and \`LD_LIBRARY_PATH\`.

After activation:

\`\`\`bash
rustc --version
cargo --version
\`\`\`

## What \`activate.sh\` does

- prepends \`./bin\` to \`PATH\`
- prepends bundled runtime libraries to \`LD_LIBRARY_PATH\`

The \`./bin\` directory contains wrapper scripts that launch the bundled Rust
toolchain from \`./toolchain\`.

## Compile For ${TARGET}

\`\`\`bash
cargo build --target ${TARGET}
\`\`\`

Example release build:

\`\`\`bash
cargo build --release --target ${TARGET}
\`\`\`

## Bundle Layout

- \`bin/\`: wrapper entrypoints such as \`rustc\` and \`cargo\`
- \`lib/\`: bundled runtime loader and shared libraries
- \`toolchain/\`: installed Rust toolchain payload
- \`activate.sh\`: shell activation helper

## Smoke Test

\`\`\`bash
. ./activate.sh
rustc --version
cargo --version
\`\`\`
EOF

echo "Created self-contained toolchain directory:"
echo "  $OUTDIR"
echo "Installed Rust components:"
echo "  $COMPONENTS"
echo "Run this on the target (without Nix):"
echo "  . ./activate.sh"
echo "  rustc --version"
echo "  cargo --version"
