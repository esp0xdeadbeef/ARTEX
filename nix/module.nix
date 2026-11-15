{
  config,
  lib,
  pkgs,
  ...
}@args:
let
  cfg = config.services.artex;
in
{
  options.services.artex = {
    enable = lib.mkEnableOption "ARTEX autonomous penetration testing platform";

    package = lib.mkOption {
      type = lib.types.package;
      default =
        (args.inputs.self or args.self or (import ../flake.nix).self)
        .packages.${pkgs.stdenv.hostPlatform.system}.artex;
      defaultText = lib.literalExpression "self.packages.${pkgs.stdenv.hostPlatform.system}.artex";
      description = "The artex package to use.";
    };

    address = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address the web UI / API listens on.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8787;
      description = "Port the web UI / API listens on.";
    };

    proxyPort = lib.mkOption {
      type = lib.types.port;
      default = 8788;
      description = "Port of the traffic recording MITM proxy (bound to loopback).";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/artex/data";
      description = "Runtime data directory (traffic index, task files, transcripts).";
    };

    keyDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/artex/keys";
      description = "Directory for jwt.key and secret.key.";
    };

    skillDir = lib.mkOption {
      type = lib.types.path;
      default = "${cfg.package}/share/artex/skills";
      defaultText = lib.literalExpression ''"''${config.services.artex.package}/share/artex/skills"'';
      description = "Skill root directory (one skill per subdirectory).";
    };

    postgres = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether to run a local PostgreSQL instance and database for ARTEX.
          Disable to use an external database (then set `database` to null and
          provide ARTEX_PG_DSN through `environmentFile` or `environment`).
        '';
      };
      user = lib.mkOption {
        type = lib.types.str;
        default = "artex";
      };
      database = lib.mkOption {
        type = lib.types.str;
        default = "artex";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 5432;
      };
    };

    settings = lib.mkOption {
      type = lib.types.nullOr lib.types.attrs;
      default = { };
      description = ''
        Contents of config.json (at minimum `database`). Set to null to skip
        writing config.json entirely (use ARTEX_PG_DSN instead).
      '';
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      defaultText = lib.literalExpression "{}";
      example = {
        "ARTEX_NOISE_PROFILE" = "balanced";
        "ANTHROPIC_API_KEY" = "/run/secrets/anthropic"; # prefer environmentFile
      };
      description = "Extra environment variables for the artex service.";
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        File with secrets (e.g. ANTHROPIC_API_KEY, OPENAI_API_KEY, ARTEX_SECRET_KEY)
        in systemd EnvironmentFile format. It is not copied to the store.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open the web UI port in the firewall.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.postgres.enable || cfg.settings == null;
        message = "services.artex: with postgres.enable = false, set settings = null and pass ARTEX_PG_DSN yourself.";
      }
    ];

    services.postgresql = lib.mkIf cfg.postgres.enable {
      enable = true;
      ensureDatabases = [ cfg.postgres.database ];
      ensureUsers = [
        {
          name = cfg.postgres.user;
          ensureDBOwnership = true;
        }
      ];
      authentication = lib.mkOverride 10 ''
        # local connections for local service users
        local ${cfg.postgres.database} ${cfg.postgres.user} trust
      '';
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];

    systemd.services.artex = {
      description = "ARTEX autonomous penetration testing platform";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "network.target"
      ]
      ++ lib.optional cfg.postgres.enable "postgresql.service";
      wants = [ "network-online.target" ];
      requires = lib.optional cfg.postgres.enable "postgresql.service";

      environment = {
        ARTEX_SKILL_DIR = cfg.skillDir;
        ARTEX_JWT_KEY_DIR = cfg.keyDir;
      }
      // lib.optionalAttrs (cfg.settings != null) {
        ARTEX_CONFIG = "/run/artex/config.json";
      }
      // lib.mapAttrs (_: toString) cfg.environment;

      preStart = lib.mkMerge [
        ''mkdir -p "${cfg.dataDir}" "${cfg.keyDir}"''
        (lib.mkIf (cfg.settings != null) ''
          umask 0077
          cat > /run/artex/config.json <<'ARTEX_CONFIG_EOF'
          ${builtins.toJSON cfg.settings}
          ARTEX_CONFIG_EOF
        '')
      ];

      serviceConfig = {
        ExecStart = lib.concatStringsSep " " [
          "${cfg.package}/bin/artex"
          "-addr ${cfg.address}:${toString cfg.port}"
          "-proxy 127.0.0.1:${toString cfg.proxyPort}"
          "-data ${cfg.dataDir}"
        ];
        StateDirectory = "artex";
        RuntimeDirectory = "artex";
        RuntimeDirectoryMode = "0700";
        EnvironmentFile = lib.optional (cfg.environmentFile != null) cfg.environmentFile;
        Restart = "on-failure";
        RestartSec = 5;
        # The agents need to launch tools and write into the data dir; keep it
        # in its own namespace but do not over-restrict (it is a pentest tool).
        ProtectSystem = "full";
        ProtectHome = "read-only";
        PrivateTmp = true;
        NoNewPrivileges = false;
        LimitNOFILE = 65536;
      };
    };

    environment.systemPackages = [ cfg.package ];
  };
}
