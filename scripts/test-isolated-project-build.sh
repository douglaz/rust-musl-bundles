#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/test-isolated-project-build.sh <project-dir> [cargo-build-args...]

Create an offline project bundle with `cargo vendor`, stage it together with the
portable Rust toolchain into a Firecracker rootfs, and run an isolated Cargo command.

Arguments:
  project-dir        Path to the Rust project to test
  cargo-build-args   Extra arguments passed to `cargo $CARGO_SUBCOMMAND`

Environment:
  FIRECRACKER_DIR         Firecracker flake ref or local path (default: github:douglaz/firecracker-sandbox)
  CARGO_SUBCOMMAND        Cargo subcommand to run in the guest (default: build)
  GUEST_OPENROUTER_API_KEY  OPENROUTER_API_KEY value exported in the guest
  GUEST_STUB_TOOLS        Comma-separated tool names to stub in the guest PATH
  PROJECT_BUNDLE_CACHE_DIR  Cache directory for vendored project bundles
  REUSE_PROJECT_BUNDLE    Reuse cached vendored project bundle when set to 1 (default: 1)
  RUST_TOOLCHAIN_DIR      Existing standalone toolchain dir to reuse
  RUST_TOOLCHAIN_VERSION  Toolchain version when building one (default: 1.94.1)
  RUST_TARGET             Rust target triple (default: x86_64-unknown-linux-musl)
  ROOTFS_MB               Rootfs size in MiB (default: computed automatically)
  BUILD_OVERHEAD_MB       Extra space for build artifacts (default: 2048)
  VM_MEM_MB               Firecracker guest RAM in MiB (default: 4096)
  VM_CPUS                 Firecracker vCPU count (default: 2)
  KEEP_WORKDIR            Keep temp directory after the run when set to 1
  FIRECRACKER_ROOTFS      Override rootfs path (default: temp dir rootfs.ext4)

Example:
  ./scripts/test-isolated-project-build.sh /path/to/my-project --release
  CARGO_SUBCOMMAND=test ./scripts/test-isolated-project-build.sh /path/to/my-project
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

create_project_source_archive() {
  local project_dir="$1"
  local archive_path="$2"

  tar \
    --sort=name \
    --mtime='UTC 1970-01-01' \
    --owner=0 \
    --group=0 \
    --numeric-owner \
    --pax-option=delete=atime,delete=ctime \
    -C "$project_dir" \
    --exclude=.git \
    --exclude=.direnv \
    --exclude=target \
    -cf "$archive_path" .
}

quote_shell_words() {
  local quoted=""
  local arg
  for arg in "$@"; do
    quoted+=" $(printf '%q' "$arg")"
  done
  printf '%s' "$quoted"
}

run_resize2fs() {
  local firecracker_dir="$1"
  local rootfs="$2"

  nix develop "$firecracker_dir" -c bash -lc '
    set -euo pipefail
    set +e
    e2fsck -fy "$1" >/dev/null
    status=$?
    set -e
    case "$status" in
      0|1|2) ;;
      *) exit "$status" ;;
    esac
    resize2fs "$1" >/dev/null
  ' _ "$rootfs"
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

build_git_root() {
  local out
  out="$(nix build --no-link --print-out-paths nixpkgs#git | tail -n1)"
  if [ -z "$out" ]; then
    echo "Failed to resolve git output from nixpkgs#git" >&2
    exit 1
  fi
  printf '%s\n' "$out"
}

build_bash_root() {
  local out
  out="$(nix build --no-link --print-out-paths nixpkgs#bash | tail -n1)"
  if [ -z "$out" ]; then
    echo "Failed to resolve bash output from nixpkgs#bash" >&2
    exit 1
  fi
  printf '%s\n' "$out"
}

build_coreutils_root() {
  local out
  out="$(nix build --no-link --print-out-paths nixpkgs#coreutils | tail -n1)"
  if [ -z "$out" ]; then
    echo "Failed to resolve coreutils output from nixpkgs#coreutils" >&2
    exit 1
  fi
  printf '%s\n' "$out"
}

build_iproute2_root() {
  local out
  out="$(nix build --no-link --print-out-paths nixpkgs#iproute2 | tail -n1)"
  if [ -z "$out" ]; then
    echo "Failed to resolve iproute2 output from nixpkgs#iproute2" >&2
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

make_guest_exec_wrapper() {
  local wrapper_path="$1"
  local target_path="$2"

  cat > "$wrapper_path" <<EOF
#!/bin/sh
exec "$target_path" "\$@"
EOF
  chmod +x "$wrapper_path"
}

make_guest_success_stub() {
  local stub_path="$1"
  local stub_name
  stub_name="$(basename "$stub_path")"

  cat > "$stub_path" <<EOF
#!/bin/sh
case "\${1:-}" in
  --version|-V|version)
    echo "${stub_name} guest stub"
    ;;
esac
exit 0
EOF
  chmod +x "$stub_path"
}

stage_store_closure() {
  local mount_dir="$1"
  shift
  local store_path
  local base_name

  sudo mkdir -p "$mount_dir/nix/store"
  for store_path in "$@"; do
    base_name="$(basename "$store_path")"
    if [ ! -e "$mount_dir/nix/store/$base_name" ]; then
      sudo cp -a "$store_path" "$mount_dir/nix/store/"
    fi
  done
}

if [ "$#" -lt 1 ]; then
  usage
fi

need_cmd cargo
need_cmd tar
need_cmd du
need_cmd awk
need_cmd mktemp
need_cmd nix
need_cmd sha256sum
need_cmd sudo
need_cmd truncate

if [ ! -e /dev/kvm ]; then
  echo "Missing /dev/kvm. Firecracker requires KVM support on the host." >&2
  exit 1
fi

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_DIR_INPUT="$1"
shift

if [ ! -d "$PROJECT_DIR_INPUT" ]; then
  echo "Project directory does not exist: $PROJECT_DIR_INPUT" >&2
  exit 1
fi

PROJECT_DIR="$(abspath "$PROJECT_DIR_INPUT")"
FIRECRACKER_DIR="${FIRECRACKER_DIR:-github:douglaz/firecracker-sandbox}"
RUST_TOOLCHAIN_VERSION="${RUST_TOOLCHAIN_VERSION:-1.94.1}"
RUST_TARGET="${RUST_TARGET:-x86_64-unknown-linux-musl}"
VM_MEM_MB="${VM_MEM_MB:-4096}"
VM_CPUS="${VM_CPUS:-2}"
KEEP_WORKDIR="${KEEP_WORKDIR:-0}"
CARGO_SUBCOMMAND="${CARGO_SUBCOMMAND:-build}"
CARGO_BUILD_ARGS=("$@")

if [ -z "${BUILD_OVERHEAD_MB:-}" ]; then
  case "$CARGO_SUBCOMMAND" in
    test)
      BUILD_OVERHEAD_MB=10240
      ;;
    *)
      BUILD_OVERHEAD_MB=2048
      ;;
  esac
fi

case "$FIRECRACKER_DIR" in
  /*|./*|../*)
    if [ ! -d "$FIRECRACKER_DIR" ]; then
      echo "Firecracker flake path does not exist: $FIRECRACKER_DIR" >&2
      exit 1
    fi
    ;;
esac

CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/rust-musl-bundles"
WORKDIR_PARENT="${WORKDIR_PARENT:-$CACHE_ROOT/workdirs}"
mkdir -p "$WORKDIR_PARENT"
WORKDIR="$(mktemp -d "$WORKDIR_PARENT/tmp.XXXXXX")"
ROOTFS="${FIRECRACKER_ROOTFS:-$WORKDIR/rootfs.ext4}"
PROJECT_BUNDLE_DIR="$WORKDIR/project"
PROJECT_VENDOR_DIR="$PROJECT_BUNDLE_DIR/vendor"
GUEST_CARGO_HOME_DIR="$WORKDIR/cargo-home"
VENDOR_CONFIG_FILE="$WORKDIR/cargo-vendor-config.toml"
PROJECT_BUNDLE_CACHE_DIR="${PROJECT_BUNDLE_CACHE_DIR:-$CACHE_ROOT/project-bundles}"
REUSE_PROJECT_BUNDLE="${REUSE_PROJECT_BUNDLE:-1}"
PROJECT_SOURCE_ARCHIVE="$WORKDIR/project-source.tar"
TOOLCHAIN_DIR="${RUST_TOOLCHAIN_DIR:-$WORKDIR/rust-toolchain}"
NATIVE_CC_ROOT="${NATIVE_CC_ROOT:-}"
GIT_ROOT="${GIT_ROOT:-}"
BASH_ROOT="${BASH_ROOT:-}"
COREUTILS_ROOT="${COREUTILS_ROOT:-}"
IPROUTE2_ROOT="${IPROUTE2_ROOT:-}"
GUEST_OPENROUTER_API_KEY="${GUEST_OPENROUTER_API_KEY:-}"
if [ -n "${GUEST_STUB_TOOLS:-}" ]; then
  GUEST_STUB_TOOLS="$GUEST_STUB_TOOLS"
elif [ "$CARGO_SUBCOMMAND" = "test" ]; then
  GUEST_STUB_TOOLS="claude,codex"
else
  GUEST_STUB_TOOLS=""
fi
if [ -n "${GUEST_TEST_THREADS:-}" ]; then
  GUEST_TEST_THREADS="$GUEST_TEST_THREADS"
elif [ "$CARGO_SUBCOMMAND" = "test" ]; then
  GUEST_TEST_THREADS=1
else
  GUEST_TEST_THREADS=""
fi
if [ -n "${GUEST_CARGO_JOBS:-}" ]; then
  GUEST_CARGO_JOBS="$GUEST_CARGO_JOBS"
elif [ "$CARGO_SUBCOMMAND" = "test" ]; then
  GUEST_CARGO_JOBS=1
else
  GUEST_CARGO_JOBS=""
fi
GUEST_NATIVE_TOOLCHAIN_DIR="$WORKDIR/native-toolchain"
GUEST_BUILD_SCRIPT="$WORKDIR/build-in-vm.sh"
GUEST_ENV_WRAPPER="$WORKDIR/usr-bin-env"
MNT_DIR="$WORKDIR/mnt"
FIRECRACKER_TMPDIR="${FIRECRACKER_TMPDIR:-$WORKDIR/firecracker-tmp}"
SUCCESS_MARKER="__ISOLATED_BUILD_OK__"
RUST_TARGET_ENV="$(printf '%s' "$RUST_TARGET" | tr '[:lower:]-' '[:upper:]_')"
RUST_TARGET_CFG_ENV="$(printf '%s' "$RUST_TARGET" | tr '-' '_')"

cleanup() {
  sudo umount "$MNT_DIR" 2>/dev/null || true
  if [ "$KEEP_WORKDIR" = "1" ]; then
    echo "Kept temp directory: $WORKDIR"
  else
    rm -rf "$WORKDIR"
  fi
}
trap cleanup EXIT

echo "Preparing project bundle from $PROJECT_DIR ..."
create_project_source_archive "$PROJECT_DIR" "$PROJECT_SOURCE_ARCHIVE"
PROJECT_SOURCE_HASH="$(sha256sum "$PROJECT_SOURCE_ARCHIVE" | awk '{print $1}')"
PROJECT_BUNDLE_CACHE_KEY="v1-${PROJECT_SOURCE_HASH}"
PROJECT_BUNDLE_CACHE_PATH="$PROJECT_BUNDLE_CACHE_DIR/$PROJECT_BUNDLE_CACHE_KEY"

if [ "$REUSE_PROJECT_BUNDLE" = "1" ] && [ -d "$PROJECT_BUNDLE_CACHE_PATH/project" ] && [ -d "$PROJECT_BUNDLE_CACHE_PATH/cargo-home" ]; then
  echo "Reusing vendored project bundle: $PROJECT_BUNDLE_CACHE_PATH"
  mkdir -p "$PROJECT_BUNDLE_DIR" "$GUEST_CARGO_HOME_DIR"
  cp -a "$PROJECT_BUNDLE_CACHE_PATH/project/." "$PROJECT_BUNDLE_DIR/"
  cp -a "$PROJECT_BUNDLE_CACHE_PATH/cargo-home/." "$GUEST_CARGO_HOME_DIR/"
else
  mkdir -p "$PROJECT_BUNDLE_DIR"
  tar -C "$PROJECT_BUNDLE_DIR" -xf "$PROJECT_SOURCE_ARCHIVE"

  echo "Vendoring Cargo dependencies ..."
  (
    cd "$PROJECT_BUNDLE_DIR"
    cargo vendor --locked --versioned-dirs vendor > "$VENDOR_CONFIG_FILE"
  )

  mkdir -p "$GUEST_CARGO_HOME_DIR"
  sed -E 's#^directory = .*$#directory = "/work/project/vendor"#' "$VENDOR_CONFIG_FILE" > "$GUEST_CARGO_HOME_DIR/config.toml"

  if [ "$REUSE_PROJECT_BUNDLE" = "1" ]; then
    echo "Caching vendored project bundle: $PROJECT_BUNDLE_CACHE_PATH"
    mkdir -p "$PROJECT_BUNDLE_CACHE_DIR"
    project_cache_tmp="$(mktemp -d "$PROJECT_BUNDLE_CACHE_DIR/.tmp.XXXXXX")"
    mkdir -p "$project_cache_tmp/project" "$project_cache_tmp/cargo-home"
    cp -a "$PROJECT_BUNDLE_DIR/." "$project_cache_tmp/project/"
    cp -a "$GUEST_CARGO_HOME_DIR/." "$project_cache_tmp/cargo-home/"
    if [ ! -e "$PROJECT_BUNDLE_CACHE_PATH" ]; then
      mv "$project_cache_tmp" "$PROJECT_BUNDLE_CACHE_PATH"
    else
      rm -rf "$project_cache_tmp"
    fi
  fi
fi

chmod -R u+w "$PROJECT_BUNDLE_DIR" "$GUEST_CARGO_HOME_DIR" 2>/dev/null || true

if [ -z "${RUST_TOOLCHAIN_DIR:-}" ]; then
  TOOLCHAIN_DIR="$CACHE_ROOT/toolchain-${RUST_TOOLCHAIN_VERSION}-${RUST_TARGET}"
fi

if [ ! -d "$TOOLCHAIN_DIR" ]; then
  echo "Building standalone Rust toolchain ..."
  mkdir -p "$(dirname "$TOOLCHAIN_DIR")"
  "$SCRIPT_DIR/build-standalone-toolchain-dir.sh" "$TOOLCHAIN_DIR" "$RUST_TOOLCHAIN_VERSION" "$RUST_TARGET"
else
  echo "Reusing standalone Rust toolchain: $TOOLCHAIN_DIR"
fi

TOOLCHAIN_LOADER_PATH="$(find "$TOOLCHAIN_DIR/lib" -maxdepth 1 -type f -name 'ld-musl-*.so.1' | head -n1 || true)"
if [ -z "$TOOLCHAIN_LOADER_PATH" ]; then
  echo "Failed to locate musl loader inside standalone toolchain: $TOOLCHAIN_DIR/lib" >&2
  exit 1
fi
TOOLCHAIN_LOADER_NAME="$(basename "$TOOLCHAIN_LOADER_PATH")"

if [ -z "$NATIVE_CC_ROOT" ]; then
  echo "Building musl C toolchain ..."
  NATIVE_CC_ROOT="$(build_musl_cc_root)"
else
  echo "Reusing musl C toolchain: $NATIVE_CC_ROOT"
fi

if [ -z "$GIT_ROOT" ]; then
  echo "Building git ..."
  GIT_ROOT="$(build_git_root)"
else
  echo "Reusing git: $GIT_ROOT"
fi

if [ -z "$BASH_ROOT" ]; then
  echo "Building bash ..."
  BASH_ROOT="$(build_bash_root)"
else
  echo "Reusing bash: $BASH_ROOT"
fi

if [ -z "$COREUTILS_ROOT" ]; then
  echo "Building coreutils ..."
  COREUTILS_ROOT="$(build_coreutils_root)"
else
  echo "Reusing coreutils: $COREUTILS_ROOT"
fi

if [ -z "$IPROUTE2_ROOT" ]; then
  echo "Building iproute2 ..."
  IPROUTE2_ROOT="$(build_iproute2_root)"
else
  echo "Reusing iproute2: $IPROUTE2_ROOT"
fi

mapfile -t NATIVE_CLOSURE_PATHS < <(nix-store -qR "$NATIVE_CC_ROOT" | sort -u)
mapfile -t GIT_CLOSURE_PATHS < <(nix-store -qR "$GIT_ROOT" | sort -u)
mapfile -t BASH_CLOSURE_PATHS < <(nix-store -qR "$BASH_ROOT" | sort -u)
mapfile -t COREUTILS_CLOSURE_PATHS < <(nix-store -qR "$COREUTILS_ROOT" | sort -u)
mapfile -t IPROUTE2_CLOSURE_PATHS < <(nix-store -qR "$IPROUTE2_ROOT" | sort -u)
NATIVE_TOOL_SEARCH_PATHS=("$NATIVE_CC_ROOT" "${NATIVE_CLOSURE_PATHS[@]}")
NATIVE_CC_PATH="$(find_closure_tool "${RUST_TARGET}-gcc" "${NATIVE_TOOL_SEARCH_PATHS[@]}" || true)"
NATIVE_CXX_PATH="$(find_closure_tool "${RUST_TARGET}-g++" "${NATIVE_TOOL_SEARCH_PATHS[@]}" || true)"
NATIVE_AR_PATH="$(find_closure_tool "${RUST_TARGET}-ar" "${NATIVE_TOOL_SEARCH_PATHS[@]}" || true)"
NATIVE_RANLIB_PATH="$(find_closure_tool "${RUST_TARGET}-ranlib" "${NATIVE_TOOL_SEARCH_PATHS[@]}" || true)"
GIT_PATH="$(find_closure_tool git "$GIT_ROOT" "${GIT_CLOSURE_PATHS[@]}" || true)"
BASH_PATH="$(find_closure_tool bash "$BASH_ROOT" "${BASH_CLOSURE_PATHS[@]}" || true)"
ENV_PATH="$(find_closure_tool env "$COREUTILS_ROOT" "${COREUTILS_CLOSURE_PATHS[@]}" || true)"
IP_PATH="$(find_closure_tool ip "$IPROUTE2_ROOT" "${IPROUTE2_CLOSURE_PATHS[@]}" || true)"

if [ -z "$NATIVE_CC_PATH" ] || [ -z "$NATIVE_CXX_PATH" ] || [ -z "$NATIVE_AR_PATH" ] || [ -z "$NATIVE_RANLIB_PATH" ]; then
  echo "Failed to locate full musl native toolchain in closure rooted at: $NATIVE_CC_ROOT" >&2
  exit 1
fi

if [ -z "$GIT_PATH" ]; then
  echo "Failed to locate git in closure rooted at: $GIT_ROOT" >&2
  exit 1
fi

if [ -z "$BASH_PATH" ]; then
  echo "Failed to locate bash in closure rooted at: $BASH_ROOT" >&2
  exit 1
fi

if [ -z "$ENV_PATH" ]; then
  echo "Failed to locate env in closure rooted at: $COREUTILS_ROOT" >&2
  exit 1
fi

if [ -z "$IP_PATH" ]; then
  echo "Failed to locate ip in closure rooted at: $IPROUTE2_ROOT" >&2
  exit 1
fi

mkdir -p "$GUEST_NATIVE_TOOLCHAIN_DIR/bin"
make_guest_exec_wrapper "$GUEST_NATIVE_TOOLCHAIN_DIR/bin/cc" "$NATIVE_CC_PATH"
make_guest_exec_wrapper "$GUEST_NATIVE_TOOLCHAIN_DIR/bin/gcc" "$NATIVE_CC_PATH"
make_guest_exec_wrapper "$GUEST_NATIVE_TOOLCHAIN_DIR/bin/${RUST_TARGET}-gcc" "$NATIVE_CC_PATH"
make_guest_exec_wrapper "$GUEST_NATIVE_TOOLCHAIN_DIR/bin/c++" "$NATIVE_CXX_PATH"
make_guest_exec_wrapper "$GUEST_NATIVE_TOOLCHAIN_DIR/bin/g++" "$NATIVE_CXX_PATH"
make_guest_exec_wrapper "$GUEST_NATIVE_TOOLCHAIN_DIR/bin/${RUST_TARGET}-g++" "$NATIVE_CXX_PATH"
make_guest_exec_wrapper "$GUEST_NATIVE_TOOLCHAIN_DIR/bin/ar" "$NATIVE_AR_PATH"
make_guest_exec_wrapper "$GUEST_NATIVE_TOOLCHAIN_DIR/bin/${RUST_TARGET}-ar" "$NATIVE_AR_PATH"
make_guest_exec_wrapper "$GUEST_NATIVE_TOOLCHAIN_DIR/bin/ranlib" "$NATIVE_RANLIB_PATH"
make_guest_exec_wrapper "$GUEST_NATIVE_TOOLCHAIN_DIR/bin/${RUST_TARGET}-ranlib" "$NATIVE_RANLIB_PATH"
make_guest_exec_wrapper "$GUEST_NATIVE_TOOLCHAIN_DIR/bin/git" "$GIT_PATH"
make_guest_exec_wrapper "$GUEST_NATIVE_TOOLCHAIN_DIR/bin/bash" "$BASH_PATH"
make_guest_exec_wrapper "$GUEST_NATIVE_TOOLCHAIN_DIR/bin/env" "$ENV_PATH"
make_guest_exec_wrapper "$GUEST_NATIVE_TOOLCHAIN_DIR/bin/ip" "$IP_PATH"

cat > "$GUEST_ENV_WRAPPER" <<'EOF'
#!/bin/sh
exec /work/native-toolchain/bin/env "$@"
EOF
chmod +x "$GUEST_ENV_WRAPPER"

if [ -n "$GUEST_STUB_TOOLS" ]; then
  IFS=',' read -r -a guest_stub_tools <<< "$GUEST_STUB_TOOLS"
  for guest_stub_tool in "${guest_stub_tools[@]}"; do
    guest_stub_tool="${guest_stub_tool#"${guest_stub_tool%%[![:space:]]*}"}"
    guest_stub_tool="${guest_stub_tool%"${guest_stub_tool##*[![:space:]]}"}"
    if [ -n "$guest_stub_tool" ]; then
      make_guest_success_stub "$GUEST_NATIVE_TOOLCHAIN_DIR/bin/$guest_stub_tool"
    fi
  done
fi

toolchain_mb="$(du -sm "$TOOLCHAIN_DIR" | awk '{print $1}')"
project_mb="$(du -sm "$PROJECT_BUNDLE_DIR" | awk '{print $1}')"
native_toolchain_mb="$(du -smc "${NATIVE_CLOSURE_PATHS[@]}" | awk 'END { print $1 }')"
git_mb="$(du -smc "${GIT_CLOSURE_PATHS[@]}" | awk 'END { print $1 }')"
bash_mb="$(du -smc "${BASH_CLOSURE_PATHS[@]}" | awk 'END { print $1 }')"
coreutils_mb="$(du -smc "${COREUTILS_CLOSURE_PATHS[@]}" | awk 'END { print $1 }')"
iproute2_mb="$(du -smc "${IPROUTE2_CLOSURE_PATHS[@]}" | awk 'END { print $1 }')"
ROOTFS_MB="${ROOTFS_MB:-$((toolchain_mb + project_mb + native_toolchain_mb + git_mb + bash_mb + coreutils_mb + iproute2_mb + BUILD_OVERHEAD_MB))}"
if [ "$ROOTFS_MB" -lt 1024 ]; then
  ROOTFS_MB=1024
fi

echo "Building Firecracker rootfs at $ROOTFS ..."
mkdir -p "$FIRECRACKER_TMPDIR"
TMPDIR="$FIRECRACKER_TMPDIR" FIRECRACKER_ROOTFS="$ROOTFS" nix run "$FIRECRACKER_DIR" -- build

echo "Resizing rootfs to ${ROOTFS_MB} MiB ..."
truncate -s "${ROOTFS_MB}M" "$ROOTFS"
run_resize2fs "$FIRECRACKER_DIR" "$ROOTFS"

guest_test_thread_args=()
if [ "$CARGO_SUBCOMMAND" = "test" ] && [ -n "$GUEST_TEST_THREADS" ]; then
  has_test_threads_arg=0
  has_harness_separator=0
  for cargo_arg in "${CARGO_BUILD_ARGS[@]}"; do
    case "$cargo_arg" in
      --)
        has_harness_separator=1
        ;;
      --test-threads|--test-threads=*)
        has_test_threads_arg=1
        ;;
    esac
  done
  if [ "$has_test_threads_arg" -eq 0 ]; then
    if [ "$has_harness_separator" -eq 1 ]; then
      guest_test_thread_args=("--test-threads=$GUEST_TEST_THREADS")
    else
      guest_test_thread_args=(-- "--test-threads=$GUEST_TEST_THREADS")
    fi
  fi
fi
cargo_build_args_quoted="$(quote_shell_words "${CARGO_BUILD_ARGS[@]}" "${guest_test_thread_args[@]}")"
cat > "$GUEST_BUILD_SCRIPT" <<EOF
#!/bin/sh
set -eu

cd /work/project
mkdir -p /work/cargo-home /work/target
export PATH=/work/native-toolchain/bin:/work/rust-toolchain/bin:\$PATH
export LD_LIBRARY_PATH=/work/rust-toolchain/lib:/work/rust-toolchain/toolchain/lib:\${LD_LIBRARY_PATH:-}
export CARGO_HOME=/work/cargo-home
export CARGO_TARGET_DIR=/work/target
EOF

if [ -n "$GUEST_CARGO_JOBS" ]; then
  cat >> "$GUEST_BUILD_SCRIPT" <<EOF
export CARGO_BUILD_JOBS=$(printf '%q' "$GUEST_CARGO_JOBS")
EOF
fi

if [ "$CARGO_SUBCOMMAND" = "test" ]; then
  cat >> "$GUEST_BUILD_SCRIPT" <<'EOF'
export CARGO_INCREMENTAL=0
if [ -n "${RUSTFLAGS:-}" ]; then
  export RUSTFLAGS="${RUSTFLAGS} -C debuginfo=0"
else
  export RUSTFLAGS="-C debuginfo=0"
fi
EOF
fi

cat >> "$GUEST_BUILD_SCRIPT" <<EOF
export CC=cc
export CXX=c++
export AR=ar
export RANLIB=ranlib
export CC_${RUST_TARGET_CFG_ENV}=cc
export CXX_${RUST_TARGET_CFG_ENV}=c++
export AR_${RUST_TARGET_CFG_ENV}=ar
export CARGO_TARGET_${RUST_TARGET_ENV}_LINKER=cc
EOF

if [ -n "$GUEST_OPENROUTER_API_KEY" ]; then
  cat >> "$GUEST_BUILD_SCRIPT" <<EOF
export OPENROUTER_API_KEY=$(printf '%q' "$GUEST_OPENROUTER_API_KEY")
EOF
fi

if [ -n "$GUEST_TEST_THREADS" ]; then
  cat >> "$GUEST_BUILD_SCRIPT" <<EOF
export RUST_TEST_THREADS=$(printf '%q' "$GUEST_TEST_THREADS")
EOF
fi

cat >> "$GUEST_BUILD_SCRIPT" <<EOF

if command -v ip >/dev/null 2>&1; then
  ip link set lo up >/dev/null 2>&1 || true
fi

echo "rustc: \$(rustc --version)"
echo "cargo: \$(cargo --version)"
echo "Running cargo ${CARGO_SUBCOMMAND} for target: ${RUST_TARGET}"

cargo_log=/work/cargo-command.log
if cargo ${CARGO_SUBCOMMAND} --frozen --offline --target ${RUST_TARGET}${cargo_build_args_quoted} >"\$cargo_log" 2>&1; then
  grep -E '^(running [0-9]+ tests|test result: )' "\$cargo_log" || true
else
  status=\$?
  tail -n 200 "\$cargo_log" || true
  exit "\$status"
fi
echo "${SUCCESS_MARKER}"
EOF
chmod +x "$GUEST_BUILD_SCRIPT"

mkdir -p "$MNT_DIR"
echo "Staging toolchain and project into rootfs ..."
sudo mount -o loop "$ROOTFS" "$MNT_DIR"
sudo mkdir -p "$MNT_DIR/lib" "$MNT_DIR/usr/bin" "$MNT_DIR/work" "$MNT_DIR/root"
sudo cp -a "$TOOLCHAIN_DIR/lib/$TOOLCHAIN_LOADER_NAME" "$MNT_DIR/lib/$TOOLCHAIN_LOADER_NAME"
stage_store_closure "$MNT_DIR" "${NATIVE_CLOSURE_PATHS[@]}"
stage_store_closure "$MNT_DIR" "${GIT_CLOSURE_PATHS[@]}"
stage_store_closure "$MNT_DIR" "${BASH_CLOSURE_PATHS[@]}"
stage_store_closure "$MNT_DIR" "${COREUTILS_CLOSURE_PATHS[@]}"
stage_store_closure "$MNT_DIR" "${IPROUTE2_CLOSURE_PATHS[@]}"
sudo cp -a "$TOOLCHAIN_DIR" "$MNT_DIR/work/rust-toolchain"
sudo cp -a "$GUEST_NATIVE_TOOLCHAIN_DIR" "$MNT_DIR/work/native-toolchain"
sudo mkdir -p "$MNT_DIR/work/project" "$MNT_DIR/work/cargo-home"
tar -C "$PROJECT_BUNDLE_DIR" -cf - . | sudo tar -C "$MNT_DIR/work/project" --no-same-owner --no-same-permissions -xf -
tar -C "$GUEST_CARGO_HOME_DIR" -cf - . | sudo tar -C "$MNT_DIR/work/cargo-home" --no-same-owner --no-same-permissions -xf -
sudo cp -a "$GUEST_BUILD_SCRIPT" "$MNT_DIR/root/build-project.sh"
sudo cp -a "$GUEST_ENV_WRAPPER" "$MNT_DIR/usr/bin/env"
sudo chmod +x "$MNT_DIR/root/build-project.sh"
sudo chmod +x "$MNT_DIR/usr/bin/env"
sudo umount "$MNT_DIR"

echo "Running isolated Firecracker build ..."
vm_output="$(
  TMPDIR="$FIRECRACKER_TMPDIR" FIRECRACKER_ROOTFS="$ROOTFS" nix run "$FIRECRACKER_DIR" -- exec --mem "$VM_MEM_MB" --cpus "$VM_CPUS" sh /root/build-project.sh
)"
printf '%s\n' "$vm_output"

if ! printf '%s\n' "$vm_output" | tr -d '\r' | grep -Fq "$SUCCESS_MARKER"; then
  echo "Isolated build failed: success marker not observed from guest build." >&2
  exit 1
fi

echo "Isolated build succeeded."
