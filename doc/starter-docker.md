# STARTER Docker build

This tree (`docker-build/`) builds an Ubuntu 22.04 LTS Docker image with the
STARTER stack compiled from pinned GitHub commits, plus a ready runtime:
external MySQL client init, system user `starter`, gsettings, and persistent
volumes. Site-specific configs live in the private sibling
`docker-build-sitedir/` (see [using-docker-build.md](using-docker-build.md)).

This directory does **not** use Autotools. Each upstream component already has
its own `./autogen.sh && ./configure && make`. Here we only orchestrate clone,
build, image assembly, and bootstrap.

---

## Tree layout

```
docker-build/
├── build.sh                 # build the image (reads versions.env)
├── run.sh                   # run the container (host network + volumes)
├── versions.env             # GitHub URL + commit for each component
├── Dockerfile               # multi-stage: builder → runtime
├── README.md                # short entry point
├── .gitignore               # ignore overlay site files + synced rag_docs
├── doc/
│   ├── starter-docker.md    # this guide
│   ├── using-docker-build.md
│   └── grafana-starter.md
├── grafana/                 # Grafana container runner (no baked dashboards)
├── explain/                 # Ollama / RAG / Piper compose + home.stex.xml.example
├── mysql-server/            # Shared MySQL (STARTER + compute_rack)
├── mysql/
│   └── starter.cnf          # legacy MySQL client/server snippets
├── overlay/
│   ├── README.md
│   └── etc/starter/         # defaults from sitedir (gitignored except .gitkeep)
├── systemd/
│   ├── starter-docker.service
│   ├── starter-docker.default.example
│   ├── mysql-server.service
│   ├── mysql-server.default.example
│   ├── explain-stack.service
│   ├── explain-stack.default.example
│   ├── starter-explain.service
│   └── starter-explain.default.example
├── scripts/
│   ├── apply-site.sh            # rsync docker-build-sitedir → overlay / rag_docs
│   ├── sync-config-overlay.sh   # copy /usr/local/etc/starter → overlay
│   ├── sync-boot-services.sh    # enabled host units → boot-services.conf
│   ├── install-systemd.sh       # install starter-docker; disable host st-*
│   ├── entrypoint.sh            # seed volumes, wait MySQL, init DB
│   ├── seed-volumes.sh          # copy defaults → etc volume (missing files only)
│   ├── init-starter-db.sh       # STARTER schema, DB users, gsettings
│   └── container-main.sh        # supervisord (core + adapters + services)
└── sql/
    └── skeleton.sql         # CREATE DATABASE/TABLE for STARTER
```
---

## What the image installs

| Component | Typical path |
|-----------|----------------|
| starter-core (`--enable-debug-server`) | `/usr/local/bin/starter-core` |
| starter-debugger | `/usr/local/bin/starter-debugger` |
| configurable-service | `/usr/local/bin/starter-configurable-service` |
| configurable-adapter | `/usr/local/bin/starter-configurable-adapter` |
| ariston plugin | `…/configurable-adapter/plugins/ariston-remotethermo.so` |
| parameters plugin | `…/configurable-adapter/plugins/parameters.so` |
| starter-explain | in-image daemon (backends via explain compose) |
| supervisor | process manager for core / adapters / services |
| system user | `starter` (uid/gid 999), home `/home/starter` |

Commits are pinned in [`versions.env`](../versions.env). To bump a component:
change `*_COMMIT`, then `./build.sh`.

---

## Boot stack (core + adapters + services)

Host systemd only starts **`starter-docker.service`**. Inside the container:

1. entrypoint seeds volumes, waits for **external mysql-server**, initializes DB/gsettings;
2. **`container-main.sh`** waits ~15s (same idea as host `ExecStartPre`);
3. **supervisord** (PID 1 for service mode) starts every program listed in
   `/usr/local/etc/starter/boot-services.conf` (including `st-explain`).

There is **no systemd inside the container**.

### `boot-services.conf`

Format (one program per line):

```
# name | user | command...
starter-core|starter|starter-core -R /usr/local/etc/starter/rules.conf
st-parameters-adapter|root|starter-configurable-adapter -c /usr/local/etc/starter/configurable-adapter/parameters.xml
st-shelly-boiler-em|starter|starter-configurable-service -c /usr/local/etc/starter/configurable-service/boiler-em.xml
```

Generate it from enabled host units (`starter-core.service` + `st-*.service`):

```bash
./scripts/sync-boot-services.sh
```

Order in the file: core, then adapters, then services. Disabled host units
(e.g. `st-chaffolink`) are omitted; add lines by hand if needed. Programs
with `User=root` run as root; others as `starter`.

If the manifest is missing or empty, the container logs a warning and starts
**starter-core only** (previous behavior).

### Host units must not double-run

With `--network=host`, native `starter-core` / `st-*` would clash with the
container. `install-systemd.sh` runs `systemctl disable --now` on
`starter-core.service` and every `st-*.service`, and enables only
`starter-docker.service`.

### Host uid 999 for Avahi / D-Bus

Container processes use uid/gid **999** (`starter`). The host system bus
authenticates by host UID: if no passwd entry exists for 999, Avahi calls fail
(`error creating avahi client: An unexpected D-Bus error occurred`) and
`starter-core` cannot see services. `install-systemd.sh` creates
`starter-docker` (uid 999, group `netdev`) when missing.

### Updating `rules.conf` on an existing volume

Seed never overwrites files already on `starter-etc`. After changing the
overlay, copy into the live volume explicitly, e.g.:

```bash
docker cp overlay/etc/starter/rules.conf starter:/usr/local/etc/starter/rules.conf
sudo systemctl restart starter-docker.service
```

---

## Typical workflow

### 1. (Optional) Prepare site configuration

Site configs live in private `docker-build-sitedir/` (not in the public repo).
Apply them into `overlay/` before build:

```bash
./scripts/apply-site.sh                          # STARTER_SITE_DIR=../docker-build-sitedir
# or refresh overlay from a live host tree:
./scripts/sync-config-overlay.sh                 # from /usr/local/etc/starter
./scripts/sync-boot-services.sh                  # enabled units → boot-services.conf
```

### 2. Build the image

```bash
./build.sh
# or:
IMAGE_TAG=starter:0.1.0 ./build.sh
./build.sh --progress=plain --no-cache
```

The overlay is stored in the image only as **defaults** at:

`/usr/local/share/starter/defaults/etc/starter/`

not as the final live configuration. MySQL is **external** (`mysql-server`).

### 3. Run (interactive)

```bash
STARTER_MYSQL_ROOT_PASSWORD='…' ./run.sh
# DB host/port defaults: STARTER_DB_HOST=127.0.0.1 STARTER_DB_PORT=3306
```

### 4. Integrate with the host (start at boot)

```bash
./scripts/apply-site.sh
./build.sh
sudo ./scripts/install-systemd.sh
# /etc/default/starter-docker from *.default.example or sitedir/host/
sudo systemctl restart starter-docker.service
sudo systemctl status starter-docker.service
```
This enables `starter-docker.service` for `multi-user.target` (boot) and
disables host `starter-core` / `st-*` so the full stack runs only in Docker.

Useful commands:

```bash
sudo systemctl start|stop|restart starter-docker.service
journalctl -u starter-docker.service -f
docker logs -f starter
```

`run.sh` modes:

| Mode | Command | Use |
|------|---------|-----|
| interactive | `./run.sh` / `./run.sh bash` | debugging |
| service | `./run.sh --service` | systemd (supervisord foreground) |
| detach | `./run.sh --detach` | background without systemd |

`run.sh` enables:

- `--network=host` — mDNS/Avahi, LAN access, ports on the host IP
- host system D-Bus socket (use the host Avahi daemon)
- `--security-opt apparmor=unconfined` — required so the container may talk to
  the host D-Bus/Avahi (Docker’s default AppArmor profile otherwise yields
  `error creating avahi client: Access denied`)
- two Docker volumes for mutable data (see below)

---

## Persistent volumes

Rebuilding the image does **not** remove these volumes.

| Volume (default) | Mount in container | Contents |
|------------------|--------------------|----------|
| `starter-etc` | `/usr/local/etc/starter` | `rules.conf`, `boot-services.conf`, service/adapter XML, `db-credentials`, DB init marker |
| `starter-home` | `/home/starter` | dconf / gsettings for user `starter` |

MySQL data lives in the shared **`mysql-server`** container
(`MYSQL_DATA_DIR` on the host), not in a starter volume.

Custom prefix: `STARTER_VOLUME_PREFIX=my ./run.sh` → `my-etc`, `my-home`.

### Bind mounts instead of named volumes

```bash
STARTER_ETC=/path/to/etc/starter \
STARTER_HOME=/path/to/home \
  ./run.sh
```

### Seeding from the overlay (never overwrites)

On start, `seed-volumes.sh`:

1. for each file in the image defaults,
2. if it does **not** already exist on the `etc` volume, copy it;
3. if it exists (including manual edits), **leave it alone**.

So: rebuild = new binaries; configs and settings stay on the volumes; DB stays on mysql-server.

### Destructive reset

```bash
docker volume rm starter-etc starter-home
# STARTER schema on mysql-server is separate — drop carefully if needed
```

---

## Database and gsettings

Requires **`mysql-server`** up on `STARTER_DB_HOST:STARTER_DB_PORT` (default `127.0.0.1:3306`).
On first start (no `.starter-db-initialized` marker on etc volume):

1. create the schema from [`sql/skeleton.sql`](../sql/skeleton.sql)
   (database `STARTER`, tables `labels`, `history`, `stats`);
2. create MySQL users `STWriter` (R/W) and `STReader` (R), host `%`;
3. write random passwords (or env-provided ones) to  
   `/usr/local/etc/starter/db-credentials` (on the etc volume);
4. set `org.starter.core` keys (`db-host`, `db-port`, `db-user`,
   `db-pass`, `rules-preprocessor`).

Fixed passwords only on **first** init:

```bash
STARTER_DB_WRITER_PASS='…' STARTER_DB_READER_PASS='…' ./run.sh
```

After an image rebuild, if the volumes still exist, credentials are
**re-read** from `db-credentials` and gsettings is realigned so the new
image does not lose the passwords.

Shared MySQL listens on `127.0.0.1:3306` (see [`mysql-server/`](../mysql-server/)).

---

## Inside the container

```bash
# DB credentials
cat /usr/local/etc/starter/db-credentials

# gsettings
runuser -u starter -- env HOME=/home/starter \
  dbus-run-session -- gsettings list-recursively org.starter.core

# core (same as the host systemd unit)
runuser -u starter -- starter-core -R /usr/local/etc/starter/rules.conf

# adapter / service (examples; depend on XML on the etc volume)
runuser -u starter -- starter-configurable-adapter \
  --config /usr/local/etc/starter/configurable-adapter/parameters.xml
```

---

## Networking

| Need | How |
|------|-----|
| mDNS discovery | `--network=host` + host D-Bus (Avahi) + `apparmor=unconfined` |
| Reach LAN devices | same network as the host |
| Be reachable (MySQL, HTTP) | ports bound on the host IP |

If you see `error creating avahi client: Access denied`, the container was
started without the AppArmor override. Use `./run.sh` (or pass
`--security-opt apparmor=unconfined`).

**Port 3306:** STARTER talks to external `mysql-server` on
`STARTER_DB_HOST`:`STARTER_DB_PORT` (default `127.0.0.1:3306`). The image does
not run mysqld.

For LAN access to adapter / parameters-plugin HTTP, set in the XML on the
etc volume (or in the overlay before the first seed):

```xml
<listen-address>0.0.0.0</listen-address>
```

Host configs often use `127.0.0.1`. The overlay default for the
**parameters plugin** HTTP bind is already `0.0.0.0:18765` so Grafana (bridge
network) can reach it via the host gateway. Seed never overwrites an existing
file on the etc volume — refresh a live install with:

```bash
docker cp overlay/etc/starter/configurable-adapter/parameters.xml \
  starter:/usr/local/etc/starter/configurable-adapter/parameters.xml
sudo systemctl restart starter-docker.service
```

### Grafana

Public tree: container runner only. MySQL / query examples:
[grafana-starter.md](grafana-starter.md). Site dashboards live in
`docker-build-sitedir/grafana/provisioning/`.

---

## Useful environment variables

| Variable | Role |
|----------|------|
| `IMAGE_TAG` | image tag for build/run (default `starter:local`) |
| `STARTER_SITE_DIR` | private site tree (default `../docker-build-sitedir`) |
| `STARTER_DB_HOST` / `STARTER_DB_PORT` | external mysql-server (default `127.0.0.1:3306`) |
| `STARTER_MYSQL_ROOT_PASSWORD` | root password for schema init |
| `STARTER_DB_WRITER_PASS` / `STARTER_DB_READER_PASS` | passwords on first init |
| `STARTER_VOLUME_PREFIX` | volume name prefix |
| `STARTER_ETC` / `STARTER_HOME` | bind mounts instead of named volumes |
| `STARTER_PULSE_UID` | desktop uid for PulseAudio mount (explain TTS) |
| `STARTER_CONTAINER_NAME` | container name (default `starter`) |
| `STARTER_APPARMOR` | AppArmor profile (default `unconfined`; needed for Avahi) |
| `STARTER_BOOT_SERVICES` | path to boot-services manifest (default under etc volume) |
| `STARTER_BOOT_SETTLE_SECS` | delay before supervisord programs (default `15`) |
| `STARTER_SERVICE_MATCH` | optional `starter-core -m` value |
| `STARTER_RULES_FILE` | rules path for core-only fallback |
| `MYSQL_DATA_DIR` / `MYSQL_ROOT_PASSWORD` | mysql-server deploy |
| `EXPLAIN_DATA_ROOT` | explain compose binds (voices, rag_docs, chroma) |

---

## What this tree does not do

- It does not run systemd *inside* the container (host systemd starts the
  container; **supervisord** manages core / adapters / services).
- It does not ship a multi-node `docker-compose` setup (all-in-one + host network).
- It does not ship site configs (use private `docker-build-sitedir`).
- It does not create a unit for configs without a host systemd unit
  (e.g. `kit-north-west.xml`).

---

## Quick reference

```bash
# full cycle
export MYSQL_ROOT_PASSWORD='…' MYSQL_DATA_DIR=/mnt/data/mysql-server-data
./mysql-server/deploy.sh
./scripts/apply-site.sh
./build.sh
STARTER_MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PASSWORD" ./run.sh --detach

# production: systemd
sudo ./mysql-server/install-systemd.sh
sudo ./scripts/install-systemd.sh
sudo systemctl restart starter-docker.service

# update binaries only (data kept on volumes)
./scripts/apply-site.sh && ./build.sh
sudo systemctl restart starter-docker.service

# refresh boot-services on an existing etc volume (seed never overwrites)
docker cp overlay/etc/starter/boot-services.conf starter:/usr/local/etc/starter/boot-services.conf
sudo systemctl restart starter-docker.service
```

Day-to-day usage with sitedir: [using-docker-build.md](using-docker-build.md).