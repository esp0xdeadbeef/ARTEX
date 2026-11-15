{
  description = "ARTEX — AI autonomous penetration testing system (self-hosted, PostgreSQL-backed)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        inherit (pkgs) lib;

        # Keep this in sync with go.mod's `go 1.x.y` line.
        go = pkgs.go_1_26;

        # Frontend: Next.js static export (`web/out`), embedded into the Go binary.
        web = pkgs.buildNpmPackage {
          pname = "artex-web";
          version = "2.2.0";
          src = ./web;
          npmDepsHash = lib.fileContents ./nix/npm-deps.hash;
          # `prepare: husky` needs a git repository to install git hooks.
          npmFlags = [ "--ignore-scripts" ];
          makeCacheWritable = true;
          env.NEXT_EXPORT = "1";
          # Next telemetry is disabled for reproducibility/no network in the sandbox.
          env.NEXT_TELEMETRY_DISABLED = "1";
          doCheck = false;
          installPhase = ''
            runHook preInstall
            # Static export lands in web/out (`output: "export"`, trailingSlash).
            mkdir -p $out
            cp -r out/. $out/
            runHook postInstall
          '';
        };

        # Single Go binary with the UI embedded (`-tags embedui`).
        artex = pkgs.buildGoModule {
          pname = "artex";
          version = "2.2.0";

          src = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./cmd
              ./agent
              ./config
              ./db
              ./docs
              ./egress
              ./enrich
              ./evidence
              ./guard
              ./intercept
              ./llmpool
              ./llmrec
              ./mcphttp
              ./notify
              ./report
              ./server
              ./sidequestion
              ./skills
              ./traffic
              ./go.mod
              ./go.sum
            ];
          };

          # The UI is a build input, not part of the Go source tree: `server/webui/dist`
          # is git-ignored, so it is dropped by the source filter and has to be
          # (re)created here — in postPatch, before the `embedui` sources are scanned.
          postPatch = ''
            mkdir -p server/webui/dist
            cp -r ${web}/. server/webui/dist/
            chmod -R u+w server/webui/dist
          '';

          # The embedded UI is the only thing -tags embedui adds; keep it on.
          tags = [ "embedui" ];

          # Holds the Go module dependency tree (hash in nix/vendorHash.nix).
          vendorHash = lib.fileContents ./nix/vendorHash;

          proxyVendor = true;
          buildFlags = [ "-trimpath" ];
          ldflags = [
            "-s"
            "-w"
            "-X main.version=${self.shortRev or "dirty"}"
          ];
          subPackages = [ "./cmd/artex" ];

          doCheck = false;

          postInstall = ''
            mkdir -p $out/share/artex
            cp -r ${./skills} $out/share/artex/skills
            cp ${./config.example.json} $out/share/artex/config.example.json
            cp ${./start.sh} $out/share/artex/start.sh
          '';

          meta = {
            description = "ARTEX — AI autonomous penetration testing system";
            homepage = "https://github.com/BaaRai/ARTEX";
            license = lib.licenses.agpl3Only;
            mainProgram = "artex";
            platforms = [
              "x86_64-linux"
              "aarch64-linux"
            ];
          };
        };

        # Convenience launcher: runs artex with paths that work outside the store.
        artexWrapped = pkgs.writeShellScriptBin "artex" ''
          set -eu
          : "''${ARTEX_SKILL_DIR:=${artex}/share/artex/skills}"
          : "''${ARTEX_JWT_KEY_DIR:=''${XDG_STATE_HOME:-$HOME/.local/state}/artex}"
          : "''${ARTEX_DATA_DIR:=''${XDG_STATE_HOME:-$HOME/.local/state}/artex/data}"
          export ARTEX_SKILL_DIR ARTEX_JWT_KEY_DIR
          mkdir -p "$ARTEX_JWT_KEY_DIR" "$ARTEX_DATA_DIR"
          exec ${artex}/bin/artex -data "$ARTEX_DATA_DIR" "$@"
        '';

        runtimeInputs = with pkgs; [
          # Container/default toolchain the agents shell out to (see Dockerfile).
          curl
          wget
          git
          jq
          unzip
          xz
          ripgrep
          vim
          python3
          nodejs
          # Network / recon staples.
          dnsutils
          iputils
          netcat-openbsd
          inetutils
          whois
          nmap
          sqlmap
          # ProjectDiscovery / web toolbox (same tools the Docker image pins).
          nuclei
          httpx
          subfinder
          katana
          ffuf
          dalfox
          bbot
        ];

        devShells.default = pkgs.mkShell {
          packages = runtimeInputs ++ [
            go
            pkgs.nodejs
            pkgs.postgresql
            pkgs.gopls
            pkgs.gotools
            pkgs.playwright-driver
          ];
          # Playwright's browsers are patched for NixOS; point playwright at them.
          PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";
          PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";
          PLAYWRIGHT_NODEJS_PATH = "${pkgs.nodejs}/bin/node";
        };
      in
      {
        packages = {
          inherit artex web;
          default = artex;
          # `nix run .` → artex with sane default paths.
          artex-cli = artexWrapped;

          # `nix run .#postgres` → a local dev PostgreSQL (e.g. for `nix develop`).
          postgres = pkgs.postgresql;
        };

        apps = {
          default = {
            type = "app";
            program = "${artexWrapped}/bin/artex";
          };
          artex = {
            type = "app";
            program = "${artex}/bin/artex";
          };
        };

        # `nix run .#container` or: nix build .#container && docker load < result
        packages.container = pkgs.dockerTools.buildLayeredImage {
          name = "artex";
          tag = "latest";
          contents = [ artex ] ++ runtimeInputs ++ [ pkgs.bashInteractive ];
          config = {
            Env = [
              "PATH=${
                lib.makeBinPath (
                  [
                    artex
                    pkgs.bash
                  ]
                  ++ runtimeInputs
                )
              }"
              "ARTEX_SKILL_DIR=/share/artex/skills"
              "ARTEX_JWT_KEY_DIR=/app/keys"
              "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
            ];
            WorkingDir = "/app";
            ExposedPorts = {
              "8787/tcp" = { };
              "8788/tcp" = { };
            };
            Entrypoint = [ "${artex}/bin/artex" ];
            Cmd = [
              "-addr"
              ":8787"
              "-proxy"
              ":8788"
              "-data"
              "/app/data"
            ];
            Volumes = {
              "/app/data" = { };
              "/app/keys" = { };
            };
          };
        };

        formatter = pkgs.nixfmt;
        inherit devShells;
      }
    )
    // {
      # NixOS module:
      #   services.artex = {
      #     enable = true;
      #     settings.database = { ... };   # optional; ARTEX_PG_DSN also works
      #   };
      nixosModules.default = ./nix/module.nix;
      nixosModules.artex = ./nix/module.nix;
    };
}
