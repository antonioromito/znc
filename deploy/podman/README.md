# Podman deployment (ZNC)

Remote and local deploy for [antonioromito/znc](https://github.com/antonioromito/znc), reusing the workflow from psyBNC but aligned with **official ZNC Docker** layout.

## How ZNC differs from psyBNC

| | psyBNC (abandoned path) | ZNC |
|---|-------------------------|-----|
| Config | `config/` + writable `data/psybnc.conf` | single data dir |
| Host mount | `config/`, `data/`, `log/` | **`data/` → `/znc-data`** only |
| Config file | `psybnc.conf` | `data/configs/znc.conf` |
| Image | UBI `Containerfile` | upstream `Dockerfile` (Alpine) |
| First setup | edit conf / ANONYMOUS | **`znc --makeconf`** (interactive) |
| Client auth | login + PASS | **`username:password`** (e.g. `/pass user:pass`) |
| Submodule | — | **`docker`** → [znc-docker](https://github.com/znc/znc-docker) |

ZNC runs as:

```text
znc --foreground --datadir /znc-data
```

Official entrypoint lives in the `docker` git submodule (`docker/slim/entrypoint.sh`).

## Host layout

```text
/opt/znc/                    # ZNC_PODMAN_ROOT
  data/                      # bind-mount → /znc-data
    configs/znc.conf
    znc.pem
    users/
```

Nothing under `data/` is copied into the image at build time.

## Submodule (required for build)

```bash
git submodule update --init docker
```

`run.sh --build` does this automatically.

## Local commands

```bash
export ZNC_PODMAN_ROOT=/opt/znc
mkdir -p "$ZNC_PODMAN_ROOT/data"

# First time only — interactive wizard (listen port, admin user, SSL):
./deploy/podman/run.sh --build
./deploy/podman/run.sh --makeconf

./deploy/podman/run.sh          # start
./deploy/podman/run.sh --down
./deploy/podman/run.sh --logs
```

Default: **host network** (`ZNC_NETWORK=host`) for outbound IRC (same rationale as psyBNC).

## Remote deploy

```bash
cp deploy/podman/deploy.secrets.local.example deploy/podman/deploy.secrets.local
chmod 600 deploy/podman/deploy.secrets.local
# edit DEPLOY_SERVER, passwords, ZNC_PODMAN_ROOT=/opt/znc

# First time (no git on server):
./deploy/podman/bootstrap-remote.sh

# Updates (git pull + optional rebuild):
./deploy/podman/deploy-remote.sh master
./deploy/podman/deploy-remote.sh master --no-build
./deploy/podman/deploy-remote.sh --logs
```

`deploy-remote.sh` runs `git submodule update --init docker` on the server.

## Migrating from psyBNC on the same VPS

1. Stop psyBNC: `PSYBNC_PODMAN_ROOT=/opt/psybnc ./deploy/podman/run.sh --down` (on server).
2. Use a **new** root, e.g. `/opt/znc` (do not reuse psyBNC `data/` — formats are incompatible).
3. Run `bootstrap-remote.sh` or `deploy-remote.sh`, then `--makeconf` to create users/networks.
4. Point Quassel at ZNC: server password `username:password`, port from `znc.conf` (often **6697** with SSL, not 8443 unless you chose that in makeconf).

## Quassel / client notes

- ZNC auth is **username:password** (or `user/network:pass` with multiple networks). Do not commit real credentials; use `deploy.secrets.local` for `auto-makeconf.sh`.
- Modules: `/msg *status help`, webadmin if enabled in makeconf.

## IPv6

If outbound IRC over IPv6 fails from the VPS, keep host networking and fix routes on the host, or set IPv4-only listeners in `znc.conf`. See psyBNC `setup-ipv6-routing.sh` on the old tree if you copied it; ZNC has no `/PREFERIPV6` command.
