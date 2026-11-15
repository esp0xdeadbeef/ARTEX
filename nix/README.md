# Running ARTEX with Nix

Everything ARTEX needs (frontend → embedded Go binary → PostgreSQL) is packaged in
[`flake.nix`](../flake.nix). No Docker, no manual `npm ci`/`go build`.

## Try it

```sh
# 1. shell with artex + the recon toolchain (nmap, nuclei, httpx, subfinder,
#    katana, ffuf, dalfox, sqlmap, bbot, node, python) and PostgreSQL
nix develop

# 2. start a throwaway PostgreSQL (in the shell)
initdb -D .pg -U artex --auth=trust
pg_ctl -D .pg -o "-p 5499 -k /tmp -c listen_addresses=127.0.0.1" -l .pg.log start
createdb -h 127.0.0.1 -p 5499 -U artex artex

# 3. run ARTEX
export ARTEX_PG_DSN="postgres://artex@127.0.0.1:5499/artex?sslmode=disable"
nix run . -- -addr 127.0.0.1:8787 -proxy 127.0.0.1:8788
```

Open <http://127.0.0.1:8787>, enter the setup token printed at startup, set a password.
Then configure an LLM in *System Settings → LLM* (or export `ANTHROPIC_API_KEY`).

## Packages

| Output | What it is |
| --- | --- |
| `.#artex` / `.#default` | Single Go binary with the Next.js UI embedded (`-tags embedui`), plus `share/artex/{skills,start.sh,config.example.json}` |
| `.#web` | The frontend static export only (`web/out`) |
| `.#artex-cli` | Wrapper that sets `ARTEX_SKILL_DIR`, `ARTEX_JWT_KEY_DIR` and `-data` to `~/.local/state/artex` (override with `ARTEX_DATA_DIR`, `ARTEX_SKILL_DIR`) |
| `.#container` | OCI image (`docker load < result`) with the runtime toolchain the Dockerfile ships |
| `.#devShells.default` | Development shell |

```sh
nix build .#artex          # ./result/bin/artex
nix run .#artex-cli        # binary with sane per-user paths
nix build .#container      # ./result = artex.tar.gz
nixfmt                    # format the flake/module
```

## Updating

Hashes are pinned next to the flake:

- `nix/vendorHash` — Go module vendor tree (`go.mod`/`go.sum` changes).
- `nix/npm-deps.hash` — frontend `package-lock.json` changes.

After a dependency bump, rebuild with a dummy hash and copy the `got:` value that
the builder prints:

```sh
echo "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" > nix/vendorHash   # or npm-deps.hash
nix build .#artex                                                             # prints the new hash
```

Also bump `go_1_26` in `flake.nix` when `go.mod`'s `go` directive moves on, and
the `version` fields when upstream releases.

## NixOS module

```nix
{
  inputs.artex.url = "github:esp0xdeadbeef/ARTEX";
  # ...
  imports = [ inputs.artex.nixosModules.default ];

  services.artex = {
    enable = true;
    address = "0.0.0.0";          # default 127.0.0.1
    port = 8787;
    openFirewall = true;
    # A local PostgreSQL (ensureDatabases/ensureUsers) is created by default,
    # and config.json is generated from `settings`:
    settings = {
      database = {
        host = "127.0.0.1";
        port = 5432;
        user = "artex";
        password = "";
        dbname = "artex";
        sslmode = "disable";
      };
    };
    environmentFile = "/run/secrets/artex";  # ANTHROPIC_API_KEY=..., ARTEX_SECRET_KEY=...
  };
}
```

Use an external database instead:

```nix
services.artex = {
  enable = true;
  postgres.enable = false;
  settings = null;                              # do not write config.json
  environment = { ARTEX_PG_DSN = "postgres://..."; };
};
```

State lives in `/var/lib/artex/{data,keys}` (traffic index, transcripts, JWT key,
secret key used for encryption at rest). The recording proxy always binds to
loopback (`127.0.0.1:8788` by default).

## Notes

- The frontend is built with `npmDepsHash` from `nix/npm-deps.hash`; `husky`'s
  `prepare` script is skipped (no git repo in the sandbox).
- `buildGoModule` gets the exported UI through `postPatch`, because
  `server/webui/dist` is git-ignored and therefore not part of the flake source.
- Tests are not run in the sandbox (`doCheck = false`): most of them need a live
  PostgreSQL instance.
