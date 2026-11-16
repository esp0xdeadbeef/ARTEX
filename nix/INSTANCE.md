# ARTEX — running instance (local)

## Access

| | |
|---|---|
| URL | http://localhost:8792/ |
| Username | `ARTEX` |
| Password | `ArtexTest12345` |
| Version | `edf2619` |
| Traffic proxy | http://127.0.0.1:8788 |

Verified: browser login on 2026-11-16 lands on `/function/tasks/`.

> The password above is a **local test credential** on a throwaway database.
> It is not a default and not part of the repository. Change it in the UI,
> or re-run `/setup` after a fresh database.

## What is running

```
artex      → 127.0.0.1:8792 -> 8787 (UI/API), 127.0.0.1:8788 -> 8788 (proxy)
artex-db   → throwaway PostgreSQL 16 (docker network artex-net)
```

Started with:

```bash
ARTEX_AUTO_DB=1 ARTEX_PORT=8792 \
OPENAI_API_KEY_FILE=$HOME/.config/sops-nix/secrets/deepseek-api \
ARTEX_LLM_PROVIDER=openai ARTEX_LLM_MODEL=deepseek-chat \
ARTEX_LLM_BASE_URL=https://api.deepseek.com/v1 \
nix run --refresh github:esp0xdeadbeef/ARTEX#container
```

## Important: this setup is ephemeral

`ARTEX_AUTO_DB=1` creates a **new** PostgreSQL on every start, so:

- the password resets to unset → `/setup/` asks again with a new token;
- tasks, findings and assets are lost when the containers are removed.

The setup token is always in the logs:

```bash
podman logs artex 2>&1 | grep "Setup token"
```

## Persistent alternative

```bash
ARTEX_PG_DSN='postgres://artex:pw@127.0.0.1:5432/artex?sslmode=disable' \
OPENAI_API_KEY_FILE=$HOME/.config/sops-nix/secrets/deepseek-api \
ARTEX_LLM_PROVIDER=openai ARTEX_LLM_MODEL=deepseek-chat \
ARTEX_LLM_BASE_URL=https://api.deepseek.com/v1 \
nix run --refresh github:esp0xdeadbeef/ARTEX#container
```

Or `podman-compose -f nix/podman-compose.yml up -d` (named `pgdata` volume).

Keep `ARTEX_KEY_DIR` (default `~/.local/state/artex/keys`) intact across
restarts: it holds the JWT signing key and the at-rest encryption key. Losing
the latter makes stored secrets undecryptable.

## Operational notes

- `nix run github:...` caches the flake revision. Use `--refresh` to get the
  latest commit, or pin one: `github:esp0xdeadbeef/ARTEX/<rev>#container`.
- `ARTEX_PORT` only changes the **host** port; the container always listens on
  8787/8788 internally.
- `*_FILE` credentials are mounted at `/run/artex-secrets/<n>-<name>`; the
  original `$HOME` path is not used (rootless podman cannot serve it).
- LLM config from the environment does not appear under *System Settings → LLM*
  ("No model profiles yet"). That page shows UI-managed profiles only; the
  engine still uses the env config — confirm with
  `podman logs artex 2>&1 | grep "LLM configured"`.

## Teardown

```bash
podman rm -f artex artex-db
podman network rm artex-net
```
