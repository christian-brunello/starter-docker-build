# STARTER Docker build

This tree (`docker-build/`) builds an Ubuntu 22.04 LTS Docker image with the
STARTER stack compiled from pinned GitHub commits, plus a ready runtime:
MySQL, system user `starter`, gsettings, and persistent volumes.

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
├── README.md                # short entry point; details in this document
├── .gitignore               # ignore site-specific files under overlay/
├── doc/
│   └── starter-docker.md    # this guide
├── mysql/
│   └── starter.cnf          # MySQL bind on 0.0.0.0
├── overlay/
│   ├── README.md
│   └── etc/starter/         # optional defaults (gitignored except .gitkeep)
├── scripts/
│   ├── sync-config-overlay.sh   # copy /usr/local/etc/starter → overlay
│   ├── entrypoint.sh            # seed volumes, start mysqld, init DB
│   ├── seed-volumes.sh          # copy defaults → etc volume (missing files only)
│   └── init-starter-db.sh       # STARTER schema, DB users, gsettings
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
| MySQL 8 | started by the entrypoint |
| system user | `starter` (uid/gid 999), home `/home/starter` |

Commits are pinned in [`versions.env`](../versions.env). To bump a component:
change `*_COMMIT`, then `./build.sh`.

---

## Typical workflow

### 1. (Optional) Prepare site configuration

Site configs should **not** live in git. Place them under `overlay/etc/starter/`
(same layout as `/usr/local/etc/starter` on the host).

```bash
./scripts/sync-config-overlay.sh                 # from /usr/local/etc/starter
./scripts/sync-config-overlay.sh /other/path     # custom source
```

Automatically skips `*.back` and similar backup files.

### 2. Build the image

```bash
./build.sh
# or:
IMAGE_TAG=starter:0.1.0 ./build.sh
./build.sh --progress=plain --no-cache
```

The overlay is stored in the image only as **defaults** at:

`/usr/local/share/starter/defaults/etc/starter/`

not as the final live configuration.

### 3. Run

```bash
./run.sh
# if the host already uses MySQL on 3306:
STARTER_MYSQL_PORT=3307 ./run.sh
```

`run.sh` enables:

- `--network=host` — mDNS/Avahi, LAN access, ports on the host IP
- host system D-Bus socket (use the host Avahi daemon)
- `--security-opt apparmor=unconfined` — required so the container may talk to
  the host D-Bus/Avahi (Docker’s default AppArmor profile otherwise yields
  `error creating avahi client: Access denied`)
- three Docker volumes for mutable data (see below)

---

## Persistent volumes

Rebuilding the image does **not** remove these volumes.

| Volume (default) | Mount in container | Contents |
|------------------|--------------------|----------|
| `starter-mysql` | `/var/lib/mysql` | MySQL data, init marker |
| `starter-etc` | `/usr/local/etc/starter` | `rules.conf`, service/adapter XML, `db-credentials` |
| `starter-home` | `/home/starter` | dconf / gsettings for user `starter` |

Custom prefix: `STARTER_VOLUME_PREFIX=my ./run.sh`
→ `my-mysql`, `my-etc`, `my-home`.

### Bind mounts instead of named volumes

```bash
STARTER_ETC=/path/to/etc/starter \
STARTER_MYSQL_DATA=/path/to/mysql \
STARTER_HOME=/path/to/home \
  ./run.sh
```

### Seeding from the overlay (never overwrites)

On start, `seed-volumes.sh`:

1. for each file in the image defaults,
2. if it does **not** already exist on the `etc` volume, copy it;
3. if it exists (including manual edits), **leave it alone**.

So: rebuild = new binaries; configs, DB, and settings stay on the volumes.

### Destructive reset

```bash
docker volume rm starter-mysql starter-etc starter-home
```

---

## Database and gsettings

On first start (empty MySQL volume):

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

MySQL listens on `0.0.0.0` (port `STARTER_MYSQL_PORT`, default 3306).

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

**Port 3306 warning:** if the host already runs MySQL, use
`STARTER_MYSQL_PORT=3307` or stop the host mysqld.

For LAN access to adapter / parameters-plugin HTTP, set in the XML on the
etc volume (or in the overlay before the first seed):

```xml
<listen-address>0.0.0.0</listen-address>
```

Host configs often use `127.0.0.1`.

---

## Useful environment variables

| Variable | Role |
|----------|------|
| `IMAGE_TAG` | image tag for build/run (default `starter:local`) |
| `STARTER_MYSQL_PORT` | mysqld port / gsettings `db-port` |
| `STARTER_DB_WRITER_PASS` / `STARTER_DB_READER_PASS` | passwords on first init |
| `STARTER_VOLUME_PREFIX` | volume name prefix |
| `STARTER_ETC` / `STARTER_MYSQL_DATA` / `STARTER_HOME` | bind mounts instead of named volumes |
| `STARTER_CONTAINER_NAME` | container name (default `starter`) |
| `STARTER_APPARMOR` | AppArmor profile (default `unconfined`; needed for Avahi) |

---

## What this tree does not do

- It does not run systemd or enable services at container boot.
- It does not ship a multi-node `docker-compose` setup (all-in-one + host network).
- It does not version production configs (they stay in local overlay / volumes).

---

## Quick reference

```bash
# full cycle
./scripts/sync-config-overlay.sh
./build.sh
STARTER_MYSQL_PORT=3307 ./run.sh

# update binaries only (data kept on volumes)
# (edit versions.env if needed)
./build.sh
STARTER_MYSQL_PORT=3307 ./run.sh
```
