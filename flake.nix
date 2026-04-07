{
  description = "Portable Rust toolchains, offline bundles, and Firecracker validation for musl builds";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay.url = "github:oxalica/rust-overlay";

    # Upstream sources pinned for auditability and reproducibility.
    rust-repo = {
      url = "github:rust-lang/rust";
      flake = false;
    };
    cargo-repo = {
      url = "github:rust-lang/cargo";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, rust-overlay, rust-repo, cargo-repo, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ (import rust-overlay) ];
        };
        # Separate import for static package set used for distribution packaging.
        # cargo is currently marked as broken on this channel, so we explicitly
        # allow broken to make this path available.
        pkgsStatic = import nixpkgs {
          inherit system;
          config = {
            allowBroken = true;
          };
        };

        muslTarget = "x86_64-unknown-linux-musl";
        rustToolchain = pkgs.rust-bin.stable.latest.default.override {
          extensions = [ "rust-src" "rustfmt" "clippy" ];
          targets = [ muslTarget ];
        };
        # These are the best-available musl-hosted toolchains in nixpkgs.
        # They are commonly called `static` binaries, but they are still linked
        # against system libraries and wrappers (not fully-static ELF for all
        # transitive runtime deps), which matters for strict offline isolation.
        rustToolchainStatic = pkgsStatic.pkgsStatic.rustc;
        cargoStatic = pkgsStatic.pkgsStatic.cargo;

        muslLinker = "${pkgs.pkgsStatic.stdenv.cc}/bin/${pkgs.pkgsStatic.stdenv.cc.targetPrefix}cc";

        mkIsolatedScriptApp = scriptName:
          flake-utils.lib.mkApp {
            drv = pkgs.writeShellApplication {
              name = scriptName;
              runtimeInputs = [ pkgs.nix ];
              text = ''
                repo_root="$PWD"
                if [ ! -x "$repo_root/scripts/${scriptName}.sh" ]; then
                  repo_root="${self.outPath}"
                fi
                exec ${pkgs.nix}/bin/nix develop "$repo_root#isolated" -c "$repo_root/scripts/${scriptName}.sh" "$@"
              '';
            };
          };

        cleanApp = flake-utils.lib.mkApp {
          drv = pkgs.writeShellApplication {
            name = "clean";
            runtimeInputs = with pkgs; [ coreutils findutils ];
            text = ''
              repo_root="$PWD"
              if [ ! -x "$repo_root/scripts/clean.sh" ]; then
                repo_root="${self.outPath}"
              fi
              exec "$repo_root/scripts/clean.sh" "$@"
            '';
          };
        };

        defaultApp = flake-utils.lib.mkApp {
          drv = pkgs.writeShellApplication {
            name = "rust-musl-bundles";
            text = ''
              printf '%s\n' \
                'rust-musl-bundles nix apps:' \
                '  nix run .#build-standalone-toolchain-dir -- <output-dir> [version] [target]' \
                '  nix run .#release-standalone-toolchain-tarball -- <output-tarball> [version] [target]' \
                '  nix run .#release-offline-project-bundle -- <project-dir> [output-tar.gz]' \
                '  nix run .#test-isolated-project-build -- <project-dir> [cargo-build-args...]' \
                '  nix run .#clean' \
                "" \
                'Interactive entrypoint:' \
                '  nix develop .#isolated'
            '';
          };
        };
      in
      {
        devShells.default = pkgs.mkShell {
          name = "rust-musl-toolchain";
          packages = with pkgs; [
            rustToolchain
            rustToolchainStatic
            cargoStatic
            pkg-config
            cacert
            openssl
            git
            bashInteractive
            pkgsStatic.stdenv.cc
          ];

          CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER = muslLinker;
          CC_x86_64_unknown_linux_musl = muslLinker;
          CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_RUSTFLAGS = "-C target-feature=+crt-static";

          shellHook = ''
            echo "Rust toolchain shell ready"
            echo "rustc: $(rustc --version)"
            echo "cargo: $(cargo --version)"
            echo "Target: ${muslTarget}"
          '';
        };

        devShells.isolated = pkgs.mkShell {
          name = "rust-musl-toolchain-isolated";
          packages = with pkgs; [
            rustToolchainStatic
            cargoStatic
            openssl
            cacert
            bashInteractive
            git
          ];

          CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER = muslLinker;
          CC_x86_64_unknown_linux_musl = muslLinker;
          CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_RUSTFLAGS = "-C target-feature=+crt-static";

          shellHook = ''
            echo "Rust toolchain shell (isolated profile) ready"
            echo "rustc (static): $(rustc --version)"
            echo "cargo (static): $(cargo --version)"
            echo "Target: ${muslTarget}"
          '';
        };

        # Reproducible source references for rust and cargo trees.
        packages.upstream-sources = pkgs.linkFarm "rust-and-cargo-sources" [
          { name = "rust-lang-rust"; path = rust-repo; }
          { name = "rust-lang-cargo"; path = cargo-repo; }
        ];

        apps = {
          default = defaultApp;
          clean = cleanApp;
          "build-standalone-toolchain-dir" = mkIsolatedScriptApp "build-standalone-toolchain-dir";
          "release-standalone-toolchain-tarball" = mkIsolatedScriptApp "release-standalone-toolchain-tarball";
          "release-offline-project-bundle" = mkIsolatedScriptApp "release-offline-project-bundle";
          "test-isolated-project-build" = mkIsolatedScriptApp "test-isolated-project-build";
        };

      }
    );
}
