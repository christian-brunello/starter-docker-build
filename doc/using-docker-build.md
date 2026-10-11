# Using docker-build (+ docker-build-sitedir)

This guide covers day-to-day use of the public framework and the optional private
site directory.

## Layout

```
…/starter/
  docker-build/              # public: build, run, scripts, examples
  docker-build-sitedir/      # private: overlay, explain corpus, Grafana, host env
```

Variable:

| Variable | Default | Meaning |
|----------|---------|---------|
| `STARTER_SITE_DIR` | `../docker-build-sitedir` | Private site tree next to this repo |

## Prerequisites

- Docker Engine + Compose plugin
- Host Avahi + D-Bus (mDNS for STARTER with `--network=host`)
- A data disk for MySQL / explain corpora (path via env, not hard-coded)
- For TTS to speakers: PulseAudio socket reachable from the starter container

## Site directory

Populate `docker-build-sitedir` (see its README). Typical contents:

```
docker-build-sitedir/
  overlay/etc/starter/     # rules, boot-services, adapters, services
  explain/
    home.stex.xml
    rag_docs/
  grafana/provisioning/    # optional datasources + dashboards
  host/                    # *.default for /etc/default
```

Apply into the public tree before building the image:

```bash
cd docker-build
./scripts/apply-site.sh
# equivalent: STARTER_SITE_DIR=/path/to/docker-build-sitedir ./scripts/apply-site.sh
```

This rsyncs overlay (including `home.stex.xml` under `explain/`) and copies
`rag_docs` for `explain/deploy.sh`. Overlay files stay gitignored in the public
repo.

Without a sitedir, the image still builds: empty overlay +
`explain/home.stex.xml.example` (127.0.0.1 endpoints).

## Deploy order

```text
mysql-server → apply-site → build → starter → explain → grafana
```

### 1. MySQL

```bash
export MYSQL_ROOT_PASSWORD='…'
export MYSQL_DATA_DIR=/mnt/data/mysql-server-data
# optional first-init rack user:
# export MYSQL_RACK_PASSWORD='…'
./mysql-server/deploy.sh
sudo ./mysql-server/install-systemd.sh   # copies sitedir host/ or *.example
```

### 2. Apply site + build STARTER

```bash
./scripts/apply-site.sh
./scripts/sync-boot-services.sh   # optional: from host units
./build.sh                        # tag starter:local
```

### 3. Run STARTER

```bash
# interactive
STARTER_MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PASSWORD" ./run.sh

# or detached / systemd
sudo ./scripts/install-systemd.sh
# edit /etc/default/starter-docker (from systemd/*.default.example or sitedir/host/)
sudo systemctl restart starter-docker.service
```

Volumes: `starter-etc` → `/usr/local/etc/starter`, `starter-home` → `/home/starter`.
Seed copies image defaults only when a path is missing; rebuilds never overwrite
existing volume files.

### 4. Explain sidecars (Ollama, RAG, Piper)

```bash
export EXPLAIN_DATA_ROOT=/mnt/data/starter/explain
./explain/deploy.sh
sudo ./explain/install-systemd.sh
```

Ensure `/etc/default/explain-stack` sets `EXPLAIN_DIR` and `EXPLAIN_DATA_ROOT`.

### 5. Grafana

```bash
# empty UI, or mounts sitedir grafana/provisioning when present
./grafana/deploy.sh
```

See [grafana-starter.md](grafana-starter.md) for MySQL datasource setup without
provisioning.

## Systemd env files

| Unit | `/etc/default/…` | Example in repo |
|------|------------------|-----------------|
| `mysql-server` | `mysql-server` | `systemd/mysql-server.default.example` |
| `starter-docker` | `starter-docker` | `systemd/starter-docker.default.example` |
| `explain-stack` | `explain-stack` | `systemd/explain-stack.default.example` |

Prefer copying from `docker-build-sitedir/host/` on house machines.

## Troubleshooting

| Symptom | Check |
|---------|--------|
| Supervisord “core-only” | `boot-services.conf` missing/empty on etc volume; run apply-site + rebuild or copy into volume |
| DB init fails | `mysql-server` up; `STARTER_DB_HOST` / password in `/etc/default/starter-docker` |
| Site dir missing | `STARTER_SITE_DIR` path; `./scripts/apply-site.sh` error message |
| Explain compose fails | `EXPLAIN_DATA_ROOT` exported / in `/etc/default/explain-stack` |
| Grafana cannot see MySQL | attach to `mysql-server_default` / `rack-net` (done by `run-grafana.sh`) |
| Parameters API from Grafana | STARTER listen `0.0.0.0:18765`; use `host.docker.internal` |
| Core `peers: 0` / rules idle (e.g. outdoor lights stuck off) | Avahi publishing on Docker bridges only — see below |

### Avahi + Docker bridges

If `starter-debugger` shows `peers: 0` / `inputs: 0` and logs contain
`Could not connect to fe80::…: Invalid argument`, restrict Avahi to the LAN NIC:

1. Set `allow-interfaces=<nic>` under `[server]` in `/etc/avahi/avahi-daemon.conf`
   (example: [`systemd/avahi-daemon.conf.example`](../systemd/avahi-daemon.conf.example);
   house value in `docker-build-sitedir/host/avahi-daemon.conf`).
2. `sudo systemctl restart avahi-daemon.service starter-docker.service`
3. Confirm `avahi-browse -art` lists `ST:*` on that NIC (IPv4) and debugger shows peers > 0.

## Related

- Image design: [starter-docker.md](starter-docker.md)
- Grafana + SQL examples: [grafana-starter.md](grafana-starter.md)
