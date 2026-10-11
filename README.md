# STARTER Docker image

Build and run the STARTER stack in Docker (Ubuntu 22.04, pinned GitHub commits,
external MySQL, persistent volumes, optional systemd at boot).

**Guides**

| Doc | Topic |
|-----|--------|
| [doc/using-docker-build.md](doc/using-docker-build.md) | Full usage: sitedir, deploy order, systemd |
| [doc/starter-docker.md](doc/starter-docker.md) | Image internals, boot-services, volumes |
| [doc/grafana-starter.md](doc/grafana-starter.md) | Grafana container + MySQL examples |
| [mysql-server/README.md](mysql-server/README.md) | Shared MySQL |
| [explain/README.md](explain/README.md) | Ollama / RAG / Piper sidecars |

## Two directories

```
…/starter/
  docker-build/           # this repo (public framework)
  docker-build-sitedir/   # private sibling: overlay, rag_docs, Grafana site, host defaults
```

Site data is **not** published here. Apply it before build:

```bash
./scripts/apply-site.sh          # default STARTER_SITE_DIR=../docker-build-sitedir
./build.sh
```

## Quick start (minimal)

```bash
# 1) MySQL (set password + data dir)
export MYSQL_ROOT_PASSWORD='…'
export MYSQL_DATA_DIR=/mnt/data/mysql-server-data
./mysql-server/deploy.sh

# 2) Optional site overlay
./scripts/apply-site.sh

# 3) Image + container
./build.sh
STARTER_MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PASSWORD" ./run.sh --detach

# 4) Optional sidecars / UI
export EXPLAIN_DATA_ROOT=/mnt/data/starter/explain
./explain/deploy.sh
./grafana/deploy.sh    # empty Grafana unless sitedir provisioning exists
```

Boot integration: `sudo ./mysql-server/install-systemd.sh`,
`sudo ./scripts/install-systemd.sh`, `sudo ./explain/install-systemd.sh`.
Copy `systemd/*.default.example` (or sitedir `host/*`) to `/etc/default/…`.
