# Running ARTEX with Nix

Everything ARTEX needs (frontend → embedded Go binary → PostgreSQL) is packaged in
[`flake.nix`](../flake.nix). No Docker, no manual `npm ci`/`go build`.

## Quick start: container (recommended)

One command; no local PostgreSQL, no manual build:

```sh
ARTEX_AUTO_DB=1 \
nix run --refresh github:esp0xdeadbeef/ARTEX#container -- -u ARTEX -p 'YourPassword123'
```

That starts ARTEX plus a **throwaway PostgreSQL** and drops you at
<http://localhost:8787/> already logged in (the password is seeded, so
`/setup` is skipped). Add your LLM key and model in the same command:

```sh
ARTEX_AUTO_DB=1 ARTEX_PORT=8787 \
OPENAI_API_KEY_FILE=$HOME/.config/sops-nix/secrets/deepseek-api \
ARTEX_LLM_PROVIDER=openai ARTEX_LLM_MODEL=deepseek-chat \
ARTEX_LLM_BASE_URL=https://api.deepseek.com/v1 \
nix run --refresh github:esp0xdeadbeef/ARTEX#container -- -u ARTEX -p 'YourPassword123'
```

A database is mandatory: either `ARTEX_AUTO_DB=1` (throwaway PostgreSQL in a
container) or `ARTEX_PG_DSN`/`ARTEX_PG_DSN_FILE` (existing one). With neither the
launcher **refuses to start** and prints the options — `ARTEX_AUTO_DB` is *not*
implied, because silently creating a database on every run hides that your data
is temporary.

### Launcher environment variables

| Variable | Default | Meaning |
| --- | --- | --- |
| `ARTEX_PORT` | `8787` | Host port for the UI/API. The container itself always listens on 8787. |
| `ARTEX_PROXY_PORT` | `8788` | Host port for the traffic-recording proxy. |
| `ARTEX_AUTO_DB` | off | Start a throwaway PostgreSQL container and wire the DSN to it. |
| `ARTEX_DATA_DIR` | `~/.local/share/artex/data` | Host dir mounted at `/app/data` (traffic, transcripts, task files). |
| `ARTEX_KEY_DIR` | `~/.local/state/artex/keys` | Host dir mounted at `/app/keys` (JWT key, at-rest encryption key). |
| `ARTEX_CONTAINER_NAME` | `artex` | Container name; also names the DB container and network. |
| `ARTEX_PODMAN` | auto | Engine to use (`podman`, `docker`, or a path). |
| `ARTEX_NETWORK` | bridge | `host` → share the host network (see below). |
| `ARTEX_HOST_NIX` | off | `1` → mount the host's `/nix` + `/run/current-system`, so the agent runs the **host's** NixOS toolchain. |
| `ARTEX_PG_DSN` / `_FILE` | — | Point at an existing PostgreSQL instead of a throwaway one. |
| `ARTEX_SECRET_KEY` / `_FILE` | generated | Key encrypting secrets at rest. |

Extra arguments after `--` go to the `artex` binary, e.g. `-- -p '...'`,
`-- -addr :9000`, `-h` for help.

### Notes and gotchas

- **Always pass `--refresh`** with `nix run github:...`. Nix caches the flake
  revision, so without it you silently run an older commit (check the
  `version <rev>` line in the banner). To be explicit, pin a revision:
  `github:esp0xdeadbeef/ARTEX/<rev>#container`.
- **The first run loads a ~2 GB image.** Later runs skip the load when the
  build is unchanged (the image carries an `artex.nix.build` label), so
  starts take seconds after the first.
- **`ARTEX_AUTO_DB=1` is ephemeral.** Every start creates a fresh database:
  your password resets and tasks/findings are lost. Use `ARTEX_PG_DSN` (or
  `nix/podman-compose.yml`, which has a named `pgdata` volume) for anything
  you want to keep. `ARTEX_DATA_DIR` alone does **not** preserve findings —
  they live in PostgreSQL.
- **Reaching host services from the agent's shell** needs `ARTEX_NETWORK=host`.
  Without it the agent's `127.0.0.1` is the container. With it, `ARTEX_PORT`
  applies directly (the app binds `:PORT` on the host) and a throwaway
  database is started on the host network too.
- **Your `$HOME` is not mounted.** Inside the container `$HOME` is `/app`; the
  agent only sees `/app/data`, `/app/keys` and `/run/artex-secrets/*`. Point
  `ARTEX_DATA_DIR` at the directory you want the agent to work in.
- **A suspended/zombie `podman` holds the store lock** and makes every podman
  command (even `podman ps`) hang. The launcher probes the engine and tells
  you how to recover; find the culprit with
  `ps -eo pid,stat,cmd | grep -E "[TZ].*podman"` and `kill -CONT <pid>`.

### Using the host's NixOS toolchain inside the container

The container ships its own toolchain, but on NixOS the host's binaries are
already self-contained: everything lives in `/nix/store` with absolute
`RUNPATH`s. Mounting `/nix` (read-only) plus `/run/current-system` makes the
**host's** tools run inside ARTEX unchanged — no extra image, no alpine, no
install step:

```sh
ARTEX_HOST_NIX=1 ARTEX_AUTO_DB=1 \
nix run --refresh github:esp0xdeadbeef/ARTEX#container -- -u ARTEX -p 'YourPassword123'
```

The agent's Bash tool then resolves `nmap`, `nuclei`, `httpx`, `ffuf`,
`sqlmap`, `python3` and **your own scripts** to `/run/current-system/sw/bin/…`
— i.e. the exact binaries you have on the host, including anything you installed
into your profile:

```sh
# from the agent shell / chat:
nmap --version          # → your host's nmap
python3 my-script.py    # → host python + host site-packages
```

Notes:

- `/nix` is mounted **read-only**; the container cannot modify your store.
- This shares binaries, not the host filesystem: `/home/deadbeef` is still not
  visible. Mount the directory you want via `ARTEX_DATA_DIR` (→ `/app/data`).
- `ARTEX_HOST_NIX=1` aborts with a clear error if `/nix` or
  `/run/current-system` is missing (i.e. not a NixOS/Nix host).
- Combined with `ARTEX_NETWORK=host` the agent gets host tools **and** host
  network services; host tools are filesystem-only otherwise.

### MCP servers in this container

MCP servers are spawned **inside** the container, so a stdio MCP server can
only use the image's toolchain (curl, nmap, nuclei, httpx, subfinder, katana,
ffuf, dalfox, sqlmap, bbot, python3, node, git, jq, …) and cannot see host
binaries or `$HOME`. To use host tooling, run the MCP server on the host and
add it in *System Settings → MCP* as an `http` (Streamable HTTP) or `sse`
transport, with `ARTEX_NETWORK=host` so the container can reach
`http://127.0.0.1:<port>/…`.

## Quick start: local (no container)

```sh
# 1. shell with artex + the recon toolchain and PostgreSQL
nix develop

# 2. throwaway PostgreSQL
initdb -D .pg -U artex --auth=trust
pg_ctl -D .pg -o "-p 5499 -k /tmp -c listen_addresses=127.0.0.1" -l .pg.log start
createdb -h 127.0.0.1 -p 5499 -U artex artex

# 3. run ARTEX (seeds the password too)
export ARTEX_PG_DSN="postgres://artex@127.0.0.1:5499/artex?sslmode=disable"
nix run . -- -addr 127.0.0.1:8787 -proxy 127.0.0.1:8788 -u ARTEX -p 'YourPassword123'
```

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

## Setting the admin password from the command line

A fresh database has no admin password, so ARTEX prints a one-time setup token and
sends you to `/setup`. To skip that, seed the password at startup:

```bash
nix run github:esp0xdeadbeef/ARTEX#container -- -u ARTEX -p 'YourPassword123'
```

- The login **username is always `ARTEX`**; `-u` is accepted for CLI familiarity
  and anything else is ignored with a log line.
- `-p` is applied **before** the setup token is minted, so no token is printed
  and `/setup` is disabled.
- An existing password is **never overwritten** — the flag then logs
  `-p ignored: a password is already set` (use `reset-password.sh` to change it).
- Minimum 12 characters; a shorter value aborts startup with a clear message.
- Security: a CLI argument is visible in `ps` to other local users. Prefer the
  setup page, `reset-password.sh`, or a file-backed secret on shared machines.

## Secrets as files (Docker/Podman, systemd)

`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `ARTEX_PG_DSN` and `ARTEX_SECRET_KEY` each also
accept a `*_FILE` variant pointing at a file that holds the value:

```sh
ARTEX_PG_DSN_FILE=/run/secrets/pg-dsn
OPENAI_API_KEY_FILE=/run/secrets/deepseek-api
ARTEX_SECRET_KEY_FILE=/run/secrets/artex-secret-key
```

The `_FILE` variable wins over the plain one; one trailing newline is stripped
(`printf`, `openssl rand -hex`, editors); an unreadable or empty file aborts startup
rather than silently falling back. All of these variables (paths included) are scrubbed
from the environment before the first worker shell is spawned, so agents cannot read the
credential off the process environment.

### Podman (rootless) + DeepSeek

`nix/podman-compose.yml` wires the image to a PostgreSQL container and DeepSeek's
OpenAI-compatible endpoint, both credentials mounted as files:

```sh
nix build .#container -o ~/.cache/artex-oci && podman load -i ~/.cache/artex-oci

umask 077; mkdir -p .secrets
openssl rand -hex 24 > .secrets/pg-password
printf 'postgres://artex:%s@postgres:5432/artex?sslmode=disable\n' "$(cat .secrets/pg-password)" > .secrets/pg-dsn
cp ~/.config/sops-nix/secrets/deepseek-api .secrets/deepseek-api

podman-compose -f nix/podman-compose.yml up -d
podman logs artex 2>&1 | grep "Setup token"
```

UI: <http://127.0.0.1:8787>. State: volumes `artex-data` (traffic/task data) and
`artex-keys` (JWT + at-rest encryption keys). `.secrets/` is git-ignored.
