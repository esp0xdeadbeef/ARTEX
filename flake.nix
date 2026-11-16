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
        # `nix run .#container`: load the OCI image into Podman (or Docker, if Podman
        # is missing) and run it as the calling user, publishing the UI and the
        # recording proxy on loopback. Extra arguments are passed to the container.
        #
        #   ARTEX_PG_DSN / ARTEX_PG_DSN_FILE       database
        #   OPENAI_API_KEY / _FILE                 LLM key (ANTHROPIC_API_KEY too)
        #   ARTEX_LLM_PROVIDER / _MODEL / _BASE_URL  e.g. DeepSeek
        #   ARTEX_DATA_DIR    host dir for /app/data (default ~/.local/share/artex/data)
        #   ARTEX_KEY_DIR     host dir for /app/keys (default ~/.local/state/artex/keys)
        #   ARTEX_CONTAINER_NAME, ARTEX_PODMAN     container name / engine override
        runContainer = pkgs.writeShellApplication {
          name = "artex-container";
          runtimeInputs = with pkgs; [
            coreutils
            findutils
            gnutar
          ];
          text = ''
            engine="''${ARTEX_PODMAN:-}"
            if [ -z "$engine" ]; then
              for candidate in podman docker; do
                if command -v "$candidate" >/dev/null 2>&1; then engine="$candidate"; break; fi
              done
            fi
            if [ -z "$engine" ]; then
              echo "artex: neither podman nor docker found — set ARTEX_PODMAN" >&2
              exit 1
            fi

            name="''${ARTEX_CONTAINER_NAME:-artex}"
            data="''${ARTEX_DATA_DIR:-''${XDG_DATA_HOME:-$HOME/.local/share}/artex/data}"
            keys="''${ARTEX_KEY_DIR:-''${XDG_STATE_HOME:-$HOME/.local/state}/artex/keys}"
            mkdir -p "$data" "$keys"

            # Load the image only when the store does not have this exact image yet.
            # Re-importing the 2 GB tarball on every start takes minutes and looks
            # like a hang; the store path is the image content hash, so comparing it
            # against the image label is an exact freshness check.
            want=${lib.escapeShellArg imageFingerprint}
            have="$("$engine" image inspect --format '{{ index .Labels "artex.nix.build" }}' localhost/artex:latest 2>/dev/null || true)"
            if [ "$have" != "$want" ]; then
              echo "artex: loading image into $engine (first run, ~2 GB)" >&2
              "$engine" load -i ${self.packages.${system}.container} >/dev/null
            fi
            "$engine" rm -f "$name" >/dev/null 2>&1 || true

            # Forward only variables that are set: an empty OPENAI_API_KEY would
            # otherwise be sent along and change provider inference.
            env_args=()
            for var in ARTEX_PG_DSN ARTEX_PG_DSN_FILE ARTEX_SECRET_KEY ARTEX_SECRET_KEY_FILE \
                       ANTHROPIC_API_KEY ANTHROPIC_API_KEY_FILE \
                       OPENAI_API_KEY OPENAI_API_KEY_FILE \
                       ARTEX_LLM_PROVIDER ARTEX_LLM_MODEL ARTEX_LLM_BASE_URL ARTEX_LLM_PROXY \
                       ARTEX_NOISE_PROFILE ARTEX_TARGET_USER_AGENT ARTEX_UNTRUSTED_BOUNDARY \
                       ARTEX_TASK_BUDGET_TOKENS ARTEX_TASK_BUDGET_TURNS \
                       ARTEX_INTENT_BUDGET_TOKENS ARTEX_INTENT_BUDGET_TURNS \
                       ARTEX_TRUSTED_PROXIES; do
              if [ -n "''${!var:-}" ]; then env_args+=(-e "$var=''${!var}"); fi
            done

            # ARTEX_NETWORK=host lets the container reach services bound to the host's
            # loopback (e.g. a local PostgreSQL), which is the common single-host setup.
            net_args=()
            if [ "''${ARTEX_NETWORK:-}" = "host" ]; then
              net_args=(--network=host)
            else
              net_args=(-p 127.0.0.1:8787:8787 -p 127.0.0.1:8788:8788)
            fi

            # A *_FILE path given on the host must be visible under the same path in
            # the container, so those files are mounted read-only.
            mount_args=()
            for var in ARTEX_PG_DSN_FILE ARTEX_SECRET_KEY_FILE ANTHROPIC_API_KEY_FILE OPENAI_API_KEY_FILE; do
              path="''${!var:-}"
              if [ -n "$path" ]; then
                if [ ! -r "$path" ]; then echo "artex: $var=$path is not readable" >&2; exit 1; fi
                mount_args+=(-v "$(realpath "$path"):$(realpath "$path"):ro")
              fi
            done

            # Fail here, not 30 s later inside the container: without a database
            # ARTEX cannot start, and a crash-restart loop just looks like a hang.
            # ARTEX_AUTO_DB=1 starts a throwaway PostgreSQL on a shared network.
            if [ -z "''${ARTEX_PG_DSN:-}" ] && [ -z "''${ARTEX_PG_DSN_FILE:-}" ] && [ "''${ARTEX_AUTO_DB:-0}" = "1" ]; then
              db_name="''${name}-db"
              db_pass="$(head -c 18 /dev/urandom | od -An -tx1 | tr -d ' \n')"
              net_args+=(--network "$name-net")
              echo "artex: starting throwaway PostgreSQL ($db_name)" >&2
              "$engine" network exists "$name-net" >/dev/null 2>&1 || "$engine" network create "$name-net" >/dev/null
              "$engine" rm -f "$db_name" >/dev/null 2>&1 || true
              "$engine" run -d --name "$db_name" --network "$name-net" \
                -e POSTGRES_USER=artex -e POSTGRES_DB=artex -e POSTGRES_PASSWORD="$db_pass" \
                docker.io/library/postgres:16-alpine >/dev/null
              echo "artex: waiting for PostgreSQL to accept connections" >&2
              for _ in $(seq 1 60); do
                if "$engine" exec "$db_name" pg_isready -U artex -d artex >/dev/null 2>&1; then break; fi
                sleep 1
              done
              env_args+=(-e "ARTEX_PG_DSN=postgres://artex:$db_pass@$db_name:5432/artex?sslmode=disable")
            fi

            if [ -z "''${ARTEX_PG_DSN:-}" ] && [ -z "''${ARTEX_PG_DSN_FILE:-}" ] && [ "''${ARTEX_AUTO_DB:-0}" != "1" ]; then
              msg=$(cat <<'MSG'
            artex: no database configured. ARTEX needs PostgreSQL. Either:

              ARTEX_PG_DSN='postgres://artex:pw@127.0.0.1:5432/artex?sslmode=disable' nix run .#container
              ARTEX_PG_DSN_FILE=/run/secrets/pg-dsn nix run .#container
              ARTEX_AUTO_DB=1 nix run .#container     # throwaway PostgreSQL in a container

            (ARTEX_NETWORK=host lets a container DSN reach a database bound to 127.0.0.1.)
            MSG
              )
              printf '%s\n' "$msg" | sed 's/^            //' >&2
              exit 2
            fi

            # A suspended/zombie podman holds the store lock, which makes every
            # podman command (including `podman ps`) block forever. Never leave
            # one behind: this script runs the container in the foreground, so a
            # Ctrl-C or SIGSTOP here must stop the engine too.
            if ! timeout 60 "$engine" info >/dev/null 2>&1; then
              echo "artex: $engine is unresponsive (a stopped/zombie podman holds the store lock)." >&2
              echo "artex: check with 'ps -eo pid,stat,cmd | grep -E \"[TZ].*podman\"';" >&2
              echo "artex: recover with 'kill -CONT <pid>' or 'kill <pid>'." >&2
              exit 1
            fi

            echo "artex: UI http://127.0.0.1:8787  ·  proxy 127.0.0.1:8788  ·  Ctrl-C to stop" >&2
            exec "$engine" run --rm --name "$name" --userns=keep-id \
              "''${net_args[@]}" \
              -v "$data:/app/data:Z" -v "$keys:/app/keys:Z" \
              "''${mount_args[@]}" "''${env_args[@]}" \
              localhost/artex:latest -addr :8787 -proxy :8788 -data /app/data "$@"
          '';
        };

        # Fingerprint of the image inputs: identical for identical builds, so the
        # runner can compare it against the image label and skip `podman load`.
        imageFingerprint = builtins.hashString "sha256" (
          builtins.concatStringsSep "|" (
            [ self.shortRev or "dirty" ]
            ++ map (p: p.outPath) (
              [
                artex
                pkgs.bashInteractive
              ]
              ++ runtimeInputs
            )
          )
        );

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

        # OCI image tarball: `nix build .#container` then `podman load -i result`.
        # A tarball is not executable, so `nix run` goes through apps.container below.
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
            # Fingerprint of the inputs this image was built from, so the runner can
            # skip a 2 GB re-import when the local store already has this build.
            Labels."artex.nix.build" = imageFingerprint;
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

        apps = {
          default = {
            type = "app";
            program = "${artexWrapped}/bin/artex";
          };
          artex = {
            type = "app";
            program = "${artex}/bin/artex";
          };
          # `nix run .#container` — runs the OCI image, not the package tarball.
          container = {
            type = "app";
            program = "${runContainer}/bin/artex-container";
            meta.description = "Run the ARTEX OCI image with Podman or Docker";
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
