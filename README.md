# Rust musl toolchain, offline bundle, and Firecracker helpers

This repository is for transporting Rust toolchains and Rust projects into
isolated environments.

It focuses on four workflows:

- a Nix-free standalone Rust toolchain directory or `.tar.gz`
- an offline Rust project bundle with `cargo vendor`
- Firecracker-based verification that the bundle can build or test in isolation

## Important note

There is still no practical way here to produce a truly self-contained,
fully-static `rustc` and `cargo` pair with no runtime dependencies at all.

The working approach in this repo is:

- use the best available musl-hosted `rustc` and `cargo`
- bundle the runtime pieces they still need
- compile Rust projects for `x86_64-unknown-linux-musl`

That gives a portable toolchain story for isolated builds even though the
compiler itself is not a single fully-static ELF.

Use the isolated dev shell when you want the host-side tools needed to create
portable bundles:

```bash
nix develop .#isolated
rustc --version
cargo --version
```

## Build a Nix-free self-contained directory

If your sandbox or VM has no Nix at all, use:

```bash
chmod +x scripts/build-standalone-toolchain-dir.sh
./scripts/build-standalone-toolchain-dir.sh ./rust-toolchain 1.94.1
```

By default this installs only the minimum components needed to compile Rust
code:

- `cargo`
- `rustc`
- `rust-std-x86_64-unknown-linux-musl`

This keeps the bundle smaller by skipping optional payloads such as docs,
`llvm-tools`, `rust-analyzer`, `clippy`, and `rustfmt`.

It produces a portable tree:

- `./rust-toolchain/bin/<tool>` wrappers such as `rustc` and `cargo`
- `./rust-toolchain/toolchain/` installed toolchain prefix
- `./rust-toolchain/lib/` runtime libraries and loader copied from the host
- `./rust-toolchain/activate.sh`
- `./rust-toolchain/README.md`

If you want extra components, override them explicitly:

```bash
RUST_COMPONENTS='cargo,rustc,rust-std-x86_64-unknown-linux-musl,rustfmt-preview,clippy-preview' \
  ./scripts/build-standalone-toolchain-dir.sh ./rust-toolchain 1.94.1
```

On a target without Nix:

```bash
cd rust-toolchain
. ./activate.sh
rustc --version
cargo --version
```

## Create a standalone toolchain tarball

Build a distributable archive with checksum and metadata:

```bash
chmod +x scripts/release-standalone-toolchain-tarball.sh
./scripts/release-standalone-toolchain-tarball.sh rust-toolchain-1.94.1-x86_64-unknown-linux-musl.tar.gz 1.94.1
```

The release helper uses the same minimal component set by default. To include
extra Rust components in the archive, set `RUST_COMPONENTS=...` before running
the helper.

The command creates:

- `rust-toolchain-1.94.1-x86_64-unknown-linux-musl.tar.gz`
- `rust-toolchain-1.94.1-x86_64-unknown-linux-musl.tar.gz.sha256`
- `rust-toolchain-1.94.1-x86_64-unknown-linux-musl.tar.gz.metadata`

Unpack and activate on the non-Nix target:

```bash
tar -xzf rust-toolchain-1.94.1-x86_64-unknown-linux-musl.tar.gz
cd rust-toolchain-1.94.1-x86_64-unknown-linux-musl
. ./activate.sh
rustc --version
cargo --version
```

## Create an offline project bundle tarball

Package a Rust project together with vendored dependencies and a working
toolchain:

```bash
chmod +x scripts/release-offline-project-bundle.sh
./scripts/release-offline-project-bundle.sh /path/to/my-project
```

This creates a tarball containing:

- `project/`
- `project/vendor/`
- `cargo-home/config.toml`
- `rust-toolchain/`
- `native-toolchain/`
- top-level `README.md`
- top-level `activate.sh`
- top-level `build-project.sh`

After unpacking on a non-Nix target:

```bash
cd my-project-offline-x86_64-unknown-linux-musl
./build-project.sh --release
```

or:

```bash
. ./activate.sh
cd project
cargo build --frozen --offline --target x86_64-unknown-linux-musl
```

Notes:

- the helper reuses the cached standalone toolchain by default when available
- vendoring covers Cargo dependencies, not arbitrary native system libraries or
  external build tools

## Test an isolated project build

Use the helper below to verify that an existing Rust project can build inside a
Firecracker microVM with:

- the standalone toolchain bundle
- vendored Cargo dependencies
- no dependency on host Cargo caches inside the guest

```bash
chmod +x scripts/test-isolated-project-build.sh
./scripts/test-isolated-project-build.sh /path/to/my-project --release
```

By default this helper uses the published Firecracker flake
`github:douglaz/firecracker-sandbox`.

Prerequisites:

- Linux x86_64
- `/dev/kvm`
- Nix with flakes
- `sudo` access for loop mounts

What it does:

- copies the project into a temp bundle, or reuses a cached vendored bundle
- runs `cargo vendor --locked` on cache miss
- builds or reuses the standalone Rust toolchain
- stages both into a Firecracker rootfs
- stages guest runtime pieces needed by common test flows:
  - `bash`
  - `/usr/bin/env`
  - `iproute2`
- brings loopback up inside the guest so localhost-based tests can run
- runs `cargo build --frozen --offline --target x86_64-unknown-linux-musl`

To run isolated tests instead of `cargo build`, set:

```bash
CARGO_SUBCOMMAND=test ./scripts/test-isolated-project-build.sh /path/to/my-project --quiet
```

Default cache locations:

- toolchain: `~/.cache/rust-musl-bundles/toolchain-<version>-<target>`
- vendored project bundle:
  `~/.cache/rust-musl-bundles/project-bundles/v1-<source-hash>`
- helper workdirs: `~/.cache/rust-musl-bundles/workdirs/`
- Firecracker temp files:
  `~/.cache/rust-musl-bundles/workdirs/<run>/firecracker-tmp/`

On repeated runs against the same project contents, the helper reuses both the
cached standalone toolchain and the cached vendored project bundle.

The helper intentionally avoids large tmpfs usage under `/tmp`. This matters
for Firecracker runs because rootfs copies and guest staging can exceed the
free space of a typical `/tmp` tmpfs on NixOS hosts.

Stable isolated test defaults:

- when `CARGO_SUBCOMMAND=test`, the helper increases rootfs sizing
- guest Cargo is serialized with `CARGO_BUILD_JOBS=1`
- guest Rust tests are serialized with `-- --test-threads=1`
- guest incremental compilation is disabled with `CARGO_INCREMENTAL=0`
- guest test debuginfo is disabled with `RUSTFLAGS=-C debuginfo=0`
- `claude` and `codex` are stubbed by default for guest test runs unless you
  override `GUEST_STUB_TOOLS`

These defaults trade peak speed for repeatability inside the microVM and were
needed to eliminate intermittent I/O failures and compiler instability during
full isolated `cargo test` runs.

Useful environment overrides:

- `FIRECRACKER_DIR=github:douglaz/firecracker-sandbox`
- `FIRECRACKER_DIR=/path/to/local/firecracker-checkout`
- `PROJECT_BUNDLE_CACHE_DIR=/path/to/project-bundle-cache`
- `REUSE_PROJECT_BUNDLE=0`
- `RUST_TOOLCHAIN_DIR=/path/to/existing/rust-toolchain`
- `ROOTFS_MB=4096`
- `VM_MEM_MB=8192`
- `VM_CPUS=4`
- `WORKDIR_PARENT=/path/to/workdirs`
- `FIRECRACKER_TMPDIR=/path/to/firecracker-temp`
- `CARGO_SUBCOMMAND=test`
- `GUEST_CARGO_JOBS=1`
- `GUEST_TEST_THREADS=1`
- `GUEST_STUB_TOOLS=claude,codex`
- `KEEP_WORKDIR=1`

Important limitations:

- vendoring solves Rust crate dependencies, not native system dependencies
- projects that need external tools or system libraries such as `openssl`,
  `pkg-config`, `clang`, or a C toolchain may still need extra guest setup
- backend-specific binaries are still project-dependent; if tests expect tools
  such as `claude` or `codex`, provide them or use `GUEST_STUB_TOOLS=...`

## Repository hygiene

Generated tarballs and extracted toolchain directories should stay out of the
repository. A `.gitignore` is included for the common release artifacts this
repo produces.

To remove generated repo artifacts and the helper cache:

```bash
chmod +x scripts/clean.sh
./scripts/clean.sh
```

This removes:

- `result/`
- `dist/`
- `rust-toolchain/`
- top-level `*.tar.gz`, `*.tar.gz.sha256`, `*.tar.gz.metadata`
- `~/.cache/rust-musl-bundles`

## Compile musl binaries on the VM

```bash
git clone <repo>
cd <repo>
export PATH=/opt/rust-toolchain/profile/bin:$PATH
cargo build --release --target x86_64-unknown-linux-musl -j "$NIX_BUILD_CORES"
```
